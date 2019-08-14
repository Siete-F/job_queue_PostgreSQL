-- PostgreSQL is not case sensitive.
-- DBeaver had some strange ideas uppon the USeOfCAse in SQL queries. Sorry for the mess.

-- Multiple shapes exist in PostgreSQL to store operational stuff:
-- * PROCEDURE Provides flexible input, no return value, could instead use notification, supports transactions.
-- * FUNCTION  Provides flexible input, 1 return value,  no notification necessary, does not support transactions
--             (i.e. is part of the parent transaction, but does not support 'COMMIT' for example). 
-- * TRIGGER   no flexible input, no return value, could instead use notification, does not support transactions.
--             As a trigger, it has access to the 
--             1)  TG_OP:   Indicating the operation that triggerd the trigger (UPDATE/DELETE/INSERT),
--             2)  NEW:     The INSERTED or UPDATED entry of the table that was triggered,
--             3)  OLD:     The DELETED entry or the entry before UPDATE.


create user test_user with encrypted password 'test_user';
------------------------------------
-- create new db
create database single_procedure_job_queue;
ALTER database single_procedure_job_queue OWNER TO test_user;
GRANT all ON DATABASE single_procedure_job_queue TO test_user;


-- Pipeline definitions:
CREATE TABLE Pipelines (
    pipe_id                 SERIAL primary key,  -- PK
    pipe_name               VARCHAR(50) not null,
    pipe_version            VARCHAR(10) not null, 
    pipe_type               VARCHAR(50) not null,
    pipe_order              SMALLINT not null,
    timestamp_minor_release DATE default current_date,
    constraint uniqPipes unique (pipe_name, pipe_version)
);
comment on column Pipelines.pipe_version is 'Full version, where only the major and minor version should be used for licensing.';


CREATE TABLE Pipeline_processes (
    pipe_id               INT,  -- PK
    process_name          VARCHAR(50),  -- PK
    process_version       VARCHAR(10) not null,
    process_order         smallint not null,
    process_input_json_schema JSONB default '{}',              -- Conceptual
    process_configuration JSONB default '{"configuration": ""}',
    primary key (pipe_id, process_name)
);


-- Create pipeline process view
-- (Rewrote al things that depended on this view, nothing depends on it anymore)
CREATE OR REPLACE VIEW public.pipeline_process_order
AS SELECT pl.pipe_id,
    pl.pipe_name,
    pl.pipe_version,
    plp.process_name,
    plp.process_version,
    lag(plp.process_name, 1) OVER (ORDER BY plp.process_order) AS prev_process_name,
    lag(plp.process_version, 1) OVER (ORDER BY plp.process_order) AS prev_process_version
   FROM pipeline_processes as plp
   join pipelines as pl on pl.pipe_id = plp.pipe_id;

-- Permissions
ALTER TABLE public.pipeline_process_order OWNER TO test_user;
GRANT ALL ON TABLE public.pipeline_process_order TO test_user;




-- Insert some example Pipelines:
insert into Pipelines (pipe_id, pipe_name, pipe_version, pipe_type, pipe_order) values 
   (1, 'activities classification',          '1.0.5',   'analysis',        1), 
   (2, 'activities classification',          '1.2.0',   'analysis',        1), 
   (3, 'wearing compliance',                 '1.2.0',   'analysis',        1), 
   (4, 'generate reports',                   '9.3.88',  'reports',         2);

-- Insert the example Pipelines definitions in pipeline_processes:
insert into pipeline_processes (pipe_id, process_name, process_version, process_order) values
   (1, 'merging_results', '1.5.2', 3),
   (1, 'classification',  '1.0.0', 2),
   (1, 'assigner',        '1.0.0', 1),
   (1, 'uploader',        '1.0.0', 4);
insert into pipeline_processes (pipe_id, process_name, process_version, process_order, process_configuration) VALUES  -- Includes configurations which are passed through to the jobs.
   (2, 'first_process',   '1.9.2', 1, '{"configuration": "first"}'),
   (2, 'second_process',  '2.2.0', 2, '{"configuration": "second process configuration"}'),
   (2, 'third_process',   '5.3.0', 3, '{"configuration": "blub"}');
insert into pipeline_processes (pipe_id, process_name, process_version, process_order) values
   (3, 'wearing_compliance', '1.5.2', 2),
   (3, 'assigner',           '1.0.0', 1),
   (3, 'wc_upload',          '1.0.0', 3);
insert into pipeline_processes (pipe_id, process_name, process_version, process_order) values
   (4, 'sumarizing_results',   '1.5.2', 1),
   (4, 'creating_report',      '1.0.0', 2);

   
-- Process handling
-- Heartbeats table, every process creates or updates it heartbeat timestamp via a stored procedure 'send_heartbeat'
CREATE TABLE Process_Heartbeats (
    Process_uuid          VARCHAR(12) not null,
    Last_Beat_Timestamp   TIMESTAMPTZ default current_timestamp,
    Server_Name           VARCHAR(50) not null,
    Process_Name          VARCHAR(50) not null,
    Process_Version       VARCHAR(10) not null,
    Process_Busy         BOOL default False,
    Process_Kill_switch   BOOL default False,
    primary key (Process_uuid)
);

-- Pipe Queue table 
CREATE TABLE Pipe_Job_Queue (
    pipe_Job_Id                SERIAL primary key,
    Request_Id                 INT,
    Pipe_Id                    INT,
    Pipe_Job_Priority          smallint default 100,   -- The priority on which jobs are sorted.
    Pipe_Job_finished          BOOL not null default false
);
comment on column pipe_Job_Queue.pipe_Job_Priority is 'Jobs are sorted based on this priority. Defaults to 100, range of smallint. Lower value is higher priority.';


-- Job Queue table
CREATE TABLE Job_Queue (
    Job_Id                      SERIAL PRIMARY KEY,
    Pipe_Job_Id                 INT,
    Pipe_Id                     INT,
    Job_Parent_Set_Elements     INT ARRAY DEFAULT NULL,
    Job_Payload                 JSONB default '{}',     -- A binairy representation of the inserted JSON object
    Job_Priority                smallint default 100,   -- The priority on which jobs are sorted. lower is more importand (currently... :) )
    Job_Finished                BOOL default null,      -- with null, we could use 'false' as 'aborted' or 'crashed'.
    Job_Created_Timestamp       TIMESTAMPTZ default current_timestamp,
    Job_Finished_Timestamp      TIMESTAMPTZ,
    Job_Creater_Process_uuid    VARCHAR(12) default NULL, -- In some sense the 'create' fields are not necessary. It may be used to see what process provided the ...
    Job_Creater_Set_Elements    INT ARRAY default NULL,   -- If 1, will be picked up if done, if x (>1), x jobs must be created and unassigned/unfinished to be picked up all at once.
    Job_Creater_Process_Name    VARCHAR(50) default NULL, --    input for the assigned process (for which the payload is). This can then easily be included if the payload is not as expected.
    Job_Creater_Process_Version VARCHAR(10) default NULL,
    Job_Assigned_Timestamp      TIMESTAMPTZ,
    Job_Assigned_Process_uuid   VARCHAR(12),              -- Jobs with both NULL or '' will be considered 'available'.
    Job_Set_Elements            INT ARRAY default NULL, -- see comment.
    Job_Process_Name            VARCHAR(50) not null,
    Job_Process_Version         VARCHAR(10) not null,
    Job_Process_Config          JSONB default '{}'
);
comment on column Job_Queue.Job_Priority is 'Jobs are sorted based on this priority. Inherits from pipe_Job_Queue. Defaults to 100, range of smallint. Lower value is higher priority.';
comment on column Job_Queue.Job_Creater_Set_Elements is 'The Job_ids of the batch that has been processed in parallel. The process picking up this job will check if all these jobs are finished and pick them up together.';
comment on column Job_Queue.Job_Set_Elements is 'The Job_ids of the batch that this job is part of. These jobs are created in parallel, to be analysed side by side.';

CREATE OR REPLACE VIEW public.job_queue_insight
AS SELECT pipe_Job_id, Pipe_id, Job_Payload, Job_Priority, Job_Finished, Job_Created_Timestamp, 
Job_Finished_Timestamp, Job_Assigned_Timestamp, Job_Creater_Process_uuid, Job_Id, Job_Parent_Set_Elements, Job_Creater_Set_Elements, Job_Set_Elements, Job_Creater_Process_Name, Job_Process_Name, 
Job_Creater_Process_Version, Job_Process_Version, Job_Assigned_Process_uuid 
FROM job_queue ORDER BY pipe_Job_id, Job_Created_Timestamp;

CREATE TABLE Job_Queue_Claim (
    Claimed_Job_Ids       INT ARRAY PRIMARY KEY,
    Claimed_Process_uuid  VARCHAR(12),
    Claimed_Timestamp     TIMESTAMPTZ DEFAULT current_timestamp
);

-------------------------------------------------------------------------------------
            -- stored procedures --
-------------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION get_pipe_order(in int, out p_order int)
AS $$
begin
    if $1 is null then RAISE EXCEPTION 'McR Error! A null was received as input in `get_pipe_order` postgreSQL function.'; end if;
    select pipe_order into p_order from pipelines where pipe_id = $1;
end;
$$ language plpgsql;



CREATE OR REPLACE FUNCTION create_or_finish_pipe_job()
    RETURNS trigger
    AS $$
declare
    a_pipe_job record;
    order_num  smallint;
    next_pipe  record;
begin
    select get_pipe_order(new.pipe_id) into order_num;

    if NEW.pipe_job_finished = True then
        if TG_OP = 'INSERT' then raise exception 'A pipe_job has been inserted in the `pipe_job_queue`, but the status is already set to finished. This is not allowed'; end if;
        -- So we are dealing with an updated pipe_job record with a pipe_job_finished field with 'true'
        -- If all similar order pipe_jobs for this request are processed, we may launch the next pipe_order processes
        if not (select bool_and(pipe_job_finished) 
                    from pipe_job_queue pjq 
                    join pipelines pl on pjq.pipe_id = pl.pipe_id 
                    where request_id = new.request_id
                    and pipe_order = order_num
                    group by request_id) then
            -- not all pipes of this order are finished yet for this request.
            return new;
        end if;
        
        -- When they are all finished, don't start successor processes when the order is 0.
        -- This special order can be used to seperate 
        IF order_num = 0 THEN
            RETURN NEW;
        END IF;
        
        -- Call every pipe job and launch it's initial `job_queue` job when it's pipe job order is in succession of the current order.
        for a_pipe_job in 
            select * from pipe_job_queue where request_id = new.request_id
        loop
            -- If pipe_job is updated to 'finished', find all 'follow-up' pipes with an order number 1 higher than this pipe
            if get_pipe_order(a_pipe_job.pipe_id) = (order_num + 1) then
                call create_entry_job(a_pipe_job.pipe_job_id, a_pipe_job.pipe_id, a_pipe_job.pipe_job_priority, row_to_json(a_pipe_job)::jsonb);
            end if;
        end loop;
        
        return new;
    end if;

    -- On insert, if it is a 'order 1' pipe, create a job for it.
    -- All other pipe_jobs (with 'order > 1') will have to wait till all these are finished.
    if TG_OP = 'INSERT' and get_pipe_order(new.pipe_id) IN (0, 1) then
        call create_entry_job(new.pipe_job_id, new.pipe_id, new.pipe_job_priority, row_to_json(new)::jsonb);
    end if;

    return null;
END;
$$ LANGUAGE plpgsql;


CREATE TRIGGER create_or_finish_pipe_job
  AFTER insert or UPDATE of pipe_job_finished ON pipe_job_Queue
  FOR EACH ROW
  EXECUTE PROCEDURE create_or_finish_pipe_job();
 
-- update a value:
-- update pipe_job_queue set pipe_job_finished = true where pipe_job_id = 1;

-- Insert some values
--insert into pipe_job_queue values
--   (1, 50, 2, 100, false),
--   (2, 65, 2, 100, false)



-- Create entry Job.
-- pipe_job_Id (part of a full request id process), pipe_id, (pipe_)job_priority, payload
create or replace
PROCEDURE create_entry_job(INT, INT, smallint, jsonb) as $$
declare
    starting_process  pipeline_processes%ROWTYPE;
    created_job_id          INT;
begin
    -- Find first process of this pipeline:
    select * into starting_process from pipeline_processes where pipe_Id = $2 and process_order = 1;

    if not found then RAISE EXCEPTION 'McR Error! No process with process_order 1 could be found for the pipe `%`.', $2; end if;

    insert into job_queue(pipe_job_Id, Pipe_Id, job_Payload, job_priority, Job_Creater_Process_uuid, Job_Creater_Process_Name, Job_Creater_Process_Version,
                Job_Process_Name, Job_Process_Version, Job_Process_Config)
        values ($1, $2, $4, $3, NULL, NULL, NULL, 
                starting_process.process_name, starting_process.process_version, starting_process.process_configuration)
        RETURNING job_id INTO created_job_id;

    UPDATE job_queue SET Job_Set_Elements = ARRAY[created_job_id] WHERE job_id = created_job_id;
end;
$$ language plpgsql

-- pipe_job_Id, pipe_id
--call create_entry_job(99,  1, '{}'::jsonb);
--call create_entry_job(100, 2, '{}'::jsonb);
--call create_entry_job(101, 1, '{}'::jsonb);



-- Creating a (mini table) type that stores 3 variables. Makes passing trough data easier.
CREATE TYPE process AS (process_name varchar, process_version varchar, process_configuration jsonb);

-- pipe_id, process name, process version
CREATE OR REPLACE FUNCTION get_next_process(in int, in VARCHAR, in VARCHAR, out next_process process) --out process_name varchar, out process_version varchar, out process_conf jsonb)
AS $$
begin
    if $1 is null then RAISE EXCEPTION 'McR Error! There is probably no job present, a NULL was received as input in get_next_process.'; end if;

    select process_name, process_version, process_configuration into next_process from pipeline_processes
           where pipe_Id = $1 
           and process_order = (
                   select pp.process_order + 1 from pipeline_processes pp
                       where pp.pipe_Id = $1
                       and   pp.process_name    = $2
                       and   pp.process_version = $3);
                   
    -- Check if a followup process was found.
    if not found then RAISE EXCEPTION 'McR Error! No process found for pipe `%` process name `%` process version `%` in table `pipeline_processes`.', $1, $2, $3; end if;
end;
$$ language plpgsql;

-- pipe_id, process name, process version
--select get_next_process(1, 'classification', '1.0.0');


-- Create Jobs.
-- This 'Create_jobs' procedure covers only the creation of jobs by processes for processes. Initial jobs for pipe_jobs need to be triggered using `create_entry_job`.
-- job_ids, Payload
create or replace PROCEDURE create_jobs(INT[], JSONB)
as $$
declare
    old_job          job_queue%ROWTYPE; 
    next_process     process%ROWTYPE;
    a_job_id         INT;
    created_job_ids  INT[];
    iPayload         JSONB;
begin
    -- Update previous job:
    update job_queue set job_finished = true, job_finished_timestamp = current_timestamp where job_id = ANY($1);

    -- Obtain previous job:
    select * into old_job from job_queue where job_id = $1[1];  --Indexing the first Array value. At least one array value must exist.
    
    -- Find process that needs to follow-up on this job:
    select * into next_process from get_next_process(old_job.pipe_id, old_job.Job_Process_Name, old_job.Job_Process_Version);
   
    -- If all is well, create the new job(s).
    -- If this procedure is rolled back, it potentially leaves gaps for the primary key values that are 'reserved' (if I understand correctly) due to the 'RETURNING' operation.
    -- (http://www.postgresqltutorial.com/postgresql-serial/)
    FOR iPayload IN SELECT * FROM jsonb_array_elements($2)
    LOOP

        insert into job_queue(pipe_job_Id, Job_Parent_Set_Elements, Pipe_Id, job_priority, job_Payload,
                      Job_Creater_Set_Elements, Job_Creater_Process_uuid, Job_Creater_Process_Name, Job_Creater_Process_Version,
                      Job_Process_Name, Job_Process_Version, Job_Process_Config)
            values (old_job.pipe_job_Id,  $1, old_job.pipe_id,  old_job.job_priority,  iPayload,
                    old_job.Job_Set_Elements, old_job.Job_Assigned_Process_uuid,  old_job.Job_Process_Name,  old_job.Job_Process_Version,
                    next_process.process_name,  next_process.process_version,  next_process.process_configuration)
            RETURNING job_id INTO a_job_id;
            
        created_job_ids := created_job_ids || a_job_id;
    END LOOP;
    
    -- Use the created_job_ids to add these created_job_ids to the `Job_Set_Elements` field of the just created jobs.
    UPDATE job_queue SET Job_Set_Elements = created_job_ids WHERE job_id = ANY(created_job_ids);

end;
$$ language plpgsql;

-- job id,  Payload(s)
--CALL create_jobs(2, '[{'payload': 'lkjf'}, {'payload': 'wioeur'}]');
--CALL create_jobs(1, '[{'payload': '3kn2l'}]');
--CALL create_jobs(1, '[{'payload': '123456789', 'second_value': [1,2,3,4,5,6,7,8,9]}]');


-- Roundup pipe.
-- Last pipe process fires this procedure
-- pipe_job_id, job_id
create or replace PROCEDURE finish_pipe(INT[], INT)
as $$
begin
    -- Update job and pipe:
    update job_queue set job_finished = true, job_finished_timestamp = current_timestamp where job_id = ANY($1);
    update pipe_job_queue set pipe_job_finished = true where pipe_job_id = $2;
end;
$$ language plpgsql;



------------
--- I could have created a (set or) batch gather job, which is then only created when all other jobs are also finished
--- But where would I then leave the payload of all the jobs that were not 'the last job' and did not have the priveledge to create this job...
--- To solve this problem I will work with a 'job_Set_Elements' which indicates the job_id's that make a 'single input' when they are all untaken/unfinished.
--- Because the diverging and converging of jobs spans over multiple jobs (A: split to 5 tasks, B: do 5 operations, C: pick up all 5 results by one process)
--- we will have to work with 'Job_Creater_Set_Elements' and 'Job_Set_Elements'
------------

-- Inserts a heartbeat of a containerHash or updates it.
create or replace
PROCEDURE send_heartbeat(VARCHAR(12), VARCHAR(50), VARCHAR(50), VARCHAR(10))
as $$
begin
    insert into
            Process_Heartbeats (
            Process_uuid,
            last_beat_Timestamp,
            Server_Name,
            Process_Name,
            Process_Version,
            Process_Busy)
        values ($1, current_timestamp, $2, $3, $4, False) on
        conflict (Process_uuid) do update
        set
            last_beat_Timestamp = current_timestamp, process_busy = False;
end;
$$ language plpgsql;



-- Find fitting job and assign it!!

-- UUID, server_name, process_name, process_version, multi_job_process
CREATE OR REPLACE FUNCTION find_job(in VARCHAR(12), in VARCHAR(50), in VARCHAR(50), in VARCHAR(10), in bool,
                                    out return_string varchar)
returns varchar AS $$
declare
    job_list    record;
    job_claim   record;
    job_ids     INT[];
    a_job       job_queue;
begin
    call send_heartbeat($1, $2, $3, $4);
    
    -- If kill_switch is set, kill app:
    if (select Process_Kill_switch from process_heartbeats where process_uuid = $1) = True then
        return_string := 'kill';
        return;
    end if;

    return_string:= 'No job found';
    if $5 then
        -- Find a single or batch of jobs that comes in a set which content is defined in `Job_Creater_Set_Elements`.
        -- This following query leaves out the 'pipe_id', this does not matter for a container that takes a job.
        -- take only 1 set when ordered on priority

        -- the set_el (Job_Creater_set_elements) is used as key to find a job batch outcome that is completely processed.
        SELECT set_el, sum(job_finished::int) = array_length(set_el, 1) AS finished INTO job_list FROM (
                    SELECT set_el, set_el[s] AS job_ids, job_priority, Job_Created_Timestamp FROM (
                        SELECT set_el,
                        generate_subscripts(set_el, 1) AS s, 
                        pipe_job_id,
                        job_priority,
                        Job_Created_Timestamp
                        FROM (
                            SELECT DISTINCT ON (Job_Creater_set_elements) Job_Creater_set_elements AS set_el, * FROM job_queue order by Job_Creater_set_elements, job_priority  -- Most inner SELECT, only unique, 'highest' priortiy set_el are returned.
                        ) AS a
                        WHERE 
                            (Job_Assigned_Process_uuid = '') IS NOT FALSE
                            AND Job_Process_Name = $3
                            AND Job_Process_Version = $4
                    ) AS b
                ) AS depending_jobs
            JOIN (
                SELECT job_id, job_finished FROM job_queue
            ) AS finish_state ON depending_jobs.job_ids = finish_state.job_id
            GROUP BY set_el
            order by min(job_priority),        -- Ordering of PRIORITY !!
                     max(Job_Created_Timestamp) LIMIT 1;        

        -- build-in function 'found' checks if 'previous query' returned any result.
        IF NOT FOUND OR NOT job_list.finished THEN RETURN; END IF;
        
        -- finding the jobs that were created by this batch operation.
        SELECT ARRAY_AGG(job_id) INTO job_ids FROM job_queue WHERE Job_Creater_set_elements = job_list.set_el;
    
        return_string := 'Retry, I lost the job race';
        INSERT INTO Job_Queue_Claim(Claimed_Job_Ids, Claimed_Process_uuid) VALUES (job_ids, $1) ON CONFLICT(Claimed_Job_Ids) DO NOTHING;
    
        --  In the context of an 'insert', the 'found' value will indicate if a value was successfully inserted.
        IF NOT FOUND THEN RETURN; END IF;
    
        -- This operation must happen seperately because we have to group above to make use of a limit 1.
        -- A loop must be used because it is not possible to store multiple rows in a variable.
        -- So here we obtain all the jobs related to the pipe_job_id and process we are ready to pick up.
        -- FOR a_job in select * from job_queue WHERE job_id = any(job_claim.job_set_elements) loop
        --     -- We are using array appending here:
        --     my_jobs := my_jobs || a_job;
        -- end loop;

        -- Finding jobs by job_id's in the job_set_elements field.
        SELECT json_agg(row_to_json(job_queue))::TEXT INTO return_string FROM job_queue WHERE Job_Creater_set_elements = job_list.set_el;
    
        -- Update all jobs in one go
        UPDATE job_queue SET
           Job_Assigned_Process_uuid = $1, 
           Job_Assigned_Timestamp = current_timestamp WHERE
           Job_Creater_set_elements = job_list.set_el;
    else
        -- Finds a single job
        select * into a_job from job_queue where
            (Job_Assigned_Process_uuid = '') is not false and  -- True for '' and NULL, accepting '' makes it easier (and less hidden) to make a job available again.
            Job_Process_Name = $3 and
            Job_Process_Version = $4
            order by job_priority, Job_Created_Timestamp limit 1 FOR UPDATE;

        -- RETURNs with 'No job found' if nothing found.
        if not found then return; end if;

        return_string := 'Retry, I lost the job race';
        INSERT INTO Job_Queue_Claim (Claimed_Job_Ids, Claimed_Process_uuid) VALUES (ARRAY[a_job.job_id], $1) ON CONFLICT(Claimed_Job_Ids) DO NOTHING;
    
        --  In the context of an 'insert', the 'found' value will indicate if a value was successfully inserted.
        IF NOT FOUND THEN RETURN; END IF;
    
        update job_queue set 
                Job_Assigned_Process_uuid = $1, 
                Job_Assigned_Timestamp = current_timestamp where
                job_id = a_job.job_id;
            
        -- the updates performed within this operation are not included in the content of the json that is returned.
        return_string := '[' || row_to_json(a_job)::TEXT || ']';
    
    end if;

    -- Set process heartbeat busy to TRUE (for now, this is nothing more than an indication).
    update process_heartbeats set process_busy = true where Process_uuid = $1;
    
END;
$$ LANGUAGE plpgsql;

----- EXAMPLE INPUT ------

-- The whole chain of processes start with a pipe_job_queue insert:
insert into pipe_job_queue values 
   (1, 50, 1, 100, false), 
   (2, 50, 4, 90,  false),  -- An order 2 pipe_id
   (3, 45, 1, 200, false),
   (4, 50, 2, 90,  false);
-- Pipe 1, 3 and 4 should be processed first, if 1 and 4 are finished, 2 will be processed.
-- During this process, 4 is prioritized above 1 and 1 above 3.

-- RESET EXAMPLE:
-- truncate job_queue; truncate job_queue_claim; truncate pipe_job_queue;

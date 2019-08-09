create user test_user with encrypted password 'test_user';
------------------------------------
-- create new db
create database single_procedure_job_queue;
ALTER database single_procedure_job_queue OWNER TO test_user;
GRANT all ON DATABASE single_procedure_job_queue TO test_user;


------------------------------------------------------------------------------------------------
-- Working concept (when run in SERIALIZABLE transaction isolation level) --
------------------------------------------------------------------------------------------------


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
comment on column Pipelines.pipe_type    is 'A pipe category that may be used for processing logic. It might be obsolete.';

CREATE TABLE Pipeline_processes (
    pipe_id               INT,  -- PK
    process_name          VARCHAR(50),  -- PK
    process_version       VARCHAR(10) not null,
    process_order         smallint not null,
    process_input_json_schema JSONB default '{}',
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




-- Insert some values
insert into Pipelines (pipe_id, pipe_name, pipe_version, pipe_type, pipe_order) values 
   (1, 'activities classification',          '1.0.5',   'analysis',        1), 
   (2, 'activities classification',          '1.2.0',   'analysis',        1), 
   (3, 'wearing compliance',                 '1.2.0',   'analysis',        1), 
   (4, 'generate reports',                   '9.3.88',  'reports',         2);
insert into pipeline_processes (pipe_id, process_name, process_version, process_order) values
   (1, 'wearing_compliance', '1.5.2', 2),
   (1, 'classification',      '1.0.0', 3),
   (1, 'assigner',           '1.0.0', 1),
   (1, 'movemonitor',        '1.0.0', 4);
insert into pipeline_processes (pipe_id, process_name, process_version, process_order, process_configuration) values
   (2, 'first_process',   '1.9.2', 1, '{"configuration": "first"}'),
   (2, 'second_process',  '2.2.0', 2, '{"configuration": "second process configuration"}'),
   (2, 'third_process',   '5.3.0', 3, '{"configuration": "blub"}');
insert into pipeline_processes (pipe_id, process_name, process_version, process_order) values
   (3, 'wearing_compliance', '1.5.2', 2),
   (3, 'assigner',           '1.0.0', 1),
   (3, 'wc_upload',        '1.0.0', 3);
insert into pipeline_processes (pipe_id, process_name, process_version, process_order) values
   (4, 'sumarizing_results', '1.5.2', 1),
   (4, 'creating_report',      '1.0.0', 2);

-- Process handling
-- Heartbeats table, every process creates or updates it heartbeat timestamp via a stored procedure 'send_heartbeat'
CREATE TABLE Process_Heartbeats (
    Process_uuid          VARCHAR(12) not null,
    last_beat_Timestamp   TIMESTAMPTZ default current_timestamp,
    Server_Name           VARCHAR(50) not null,
    Process_Name          VARCHAR(50) not null,
    Process_Version       VARCHAR(10) not null,
    Process_Bussy         BOOL default False,
    Process_Kill_switch   BOOL default False,
    primary key (Process_uuid)
);

-- Pipe Queue table 
CREATE TABLE pipe_job_Queue (
    pipe_job_Id                SERIAL primary key,
    Request_Id                 INT,
    Pipe_Id                    INT,
    pipe_job_Priority          smallint default 100,   -- The priority on which jobs are sorted.
    pipe_job_finished          BOOL not null default false
);

comment on column pipe_job_Queue.pipe_job_Priority is 'Jobs are sorted based on this priority. Defaults to 100, range of smallint.';


-- Job Queue table
CREATE TABLE Job_Queue (
    Job_Id                     SERIAL primary key,
    pipe_job_Id                INT,
    Pipe_Id                    INT,
    job_Payload                JSONB default '{}',     -- A binairy representation of the inserted JSON object
    job_Priority               smallint default 100,   -- The priority on which jobs are sorted.
    job_finished               BOOL default null,      -- with null, we could use 'false' as 'aborted' or 'crashed'.
    Job_Create_Timestamp       TIMESTAMPTZ default current_timestamp,
    Job_Finished_Timestamp     TIMESTAMPTZ,
    Job_Create_Process_uuid    VARCHAR(12) default '', -- In some sense the 'create' fields are not necessary. It may be used to see what process provided the ...
    Job_Create_Set_Size        INT default 1,          -- If 1, will be picked up if done, if x (>1), x jobs must be created and unassigned/unfinished to be picked up all at once.
    Job_Create_Process_Name    VARCHAR(50) default '', --    input for the assigned process (for which the payload is). This can then easily be included if the payload is not as expected.
    Job_Create_Process_Version VARCHAR(10) default '',
    Job_Assign_Timestamp       TIMESTAMPTZ,
    Job_Assign_Process_uuid    VARCHAR(12),
    job_Assign_Set_Size        INT default 1,          -- see comment.
    Job_Assign_Process_Name    VARCHAR(50) not null,
    Job_Assign_Process_Version VARCHAR(10) not null,
    Job_Assign_Process_Config  JSONB default '{}'
);
comment on column Job_Queue.job_Priority is 'Jobs are sorted based on this priority. Inherits from pipe_job_Queue. Defaults to 100, range of smallint.';
comment on column Job_Queue.Job_Create_Set_Size is 'The size of the batch that will be processed by a single instance of the assigned process.';
comment on column Job_Queue.Job_Assign_Set_Size is 'The number of jobs that are created in parallel, to be analysed side by side.';


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
	a_pipe_job     record;
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
	if TG_OP = 'INSERT' and get_pipe_order(new.pipe_id) = 1 then
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
begin
	-- Find first process of this pipeline:
	select * into starting_process from pipeline_processes where pipe_Id = $2 and process_order = 1;

	if not found then RAISE EXCEPTION 'McR Error! No process with process_order 1 could be found for the pipe `%`.', $2; end if;

	insert into job_queue(pipe_job_Id, Pipe_Id, job_Payload, job_priority, job_create_Process_uuid, Job_Create_Process_Name, Job_Create_Process_Version,
			Job_Assign_Process_Name, Job_Assign_Process_Version, Job_Assign_Process_config)
	values ($1, $2, $4, $3, '', '', '', 
			starting_process.process_name, starting_process.process_version, starting_process.process_configuration);
end;
$$ language plpgsql

-- pipe_job_Id, pipe_id
--call create_entry_job(99, 1, '{}'::jsonb);
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



-- Create Job.
-- This 'Create_job' procedure covers only the creation of jobs by processes for processes. The first job needs to be triggered otherwise.
-- set size: if 2, the next process will only be assigned this (and it's companion job) if both are finished.
-- job_id, set size, Payload
create or replace PROCEDURE create_job(INT, INT, JSONB)
as $$
declare
	old_job          job_queue%ROWTYPE; 
	next_process     process%ROWTYPE;
begin
	-- Update previous job:
	update job_queue set job_finished = true, job_finished_timestamp = current_timestamp where job_id = $1;

	-- Obtain previous job:
	select * into old_job from job_queue where job_id = $1;
	
	-- Find process that needs to follow-up on this job:
	select * into next_process from get_next_process(old_job.pipe_id, old_job.Job_assign_Process_Name, old_job.Job_assign_Process_Version);
   
    -- If all is well, create the new job.
	insert into
		job_queue(pipe_job_Id, Pipe_Id, job_priority, job_Payload, Job_Create_Set_Size, Job_Assign_Set_Size, job_create_Process_uuid, Job_Create_Process_Name, Job_Create_Process_Version,
				  Job_Assign_Process_Name, Job_Assign_Process_Version, Job_Assign_Process_config)
	values (old_job.pipe_job_Id,  old_job.pipe_id,  old_job.job_priority,  $3,  old_job.Job_Assign_Set_Size,  $2,  old_job.job_assign_process_uuid,  old_job.job_assign_process_name,  old_job.job_assign_process_version,
			next_process.process_name,  next_process.process_version,  next_process.process_configuration);

end;
$$ language plpgsql;

-- job id,  set size,   Payload
--CALL create_job(2, 1, '{}');
--CALL create_job(1, 2, '{}');
--CALL create_job(1, 1, '{}');



-- Roundup pipe.
-- Last pipe process fires this procedure
-- pipe_job_id, job_id
create or replace PROCEDURE finish_pipe(INT, INT)
as $$
begin
	-- Update job and pipe:
	update job_queue set job_finished = true, job_finished_timestamp = current_timestamp where job_id = $2;
	update pipe_job_queue set pipe_job_finished = true where pipe_job_id = $1;
end;
$$ language plpgsql;



------------
--- I could have created a (set or) batch  gather job, which is then only created when all other jobs are also finished
--- But where would I then leave the payload of all the jobs that were not 'the last job' and did not have the priveledge to create this job...
--- To solve this problem I will work with a 'job_set_size' which indicates how many jobs make a 'single input' when they are all untaken/unfinished.
--- Because the diverging and converging of jobs spans over multiple jobs (A: split to 5 tasks, B: do 5 operations, C: pick up all 5 results by one process)
--- we will have to work with 'Job_Create_Set_Size' and 'Job_Assign_Set_Size'
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
			Process_Bussy)
		values ($1, current_timestamp, $2, $3, $4, False) on
		conflict (Process_uuid) do update
		set
			last_beat_Timestamp = current_timestamp, process_bussy = False;
end;
$$ language plpgsql;



-- Find fitting job and assign it!!
-- PROCEDURE Provides flexible input, no return value, so can use notification, supports transactions.
-- FUNCTION  Provides flexible input, 1 return value,  no notification necessary, does not support transactions. 
-- TRIGGER   no flexible input, no return value, so can use notification, does not support transactions.

-- Since we are working within a single transaction
-- Trying 'function' approach: 
-- UUID, server_name, process_name, process_version, multi_job_process
CREATE OR REPLACE FUNCTION find_job(in VARCHAR(12), in VARCHAR(50), in VARCHAR(50), in VARCHAR(10), in bool,
                                    out output varchar)
returns varchar AS $$
declare
    job_list    record;
    my_jobs     job_queue[];
    a_job       job_queue;
begin
	call send_heartbeat($1, $2, $3, $4);
	
	-- If kill_switch is set, kill app:
	if (select Process_Kill_switch from process_heartbeats where process_uuid = $1) = True then
		output := 'kill';
		return;
	end if;

	output:= 'No job found';
	if $5 then
		-- This following query leaves out the 'pipe_id', this does not matter for a container that takes a job.
		-- Find a single or batch of jobs that comes in a set, the size of `job_Create_set_size`.
		-- take only 1 set when ordered on priority
		select pipe_job_id, (count(pipe_job_id) = max(job_Create_set_size)) as full_set_present
			into job_list from job_queue where 
			(job_assign_Process_uuid = '')  is not false and  -- True for '' and NULL, accepting '' makes it easier (and less hidden) to make a job available again.
			job_assign_process_name =  $3 and
		    job_assign_process_version = $4
		   	group by pipe_job_id
		   	order by full_set_present desc,
		   		min(job_priority),
		   		max(job_create_timestamp)
		    limit 1;
	   
		-- build-in: 'found', checks if 'previous query' returned any result.
		if not found or not job_list.full_set_present then return; end if;
	
		-- This operation must happen seperately because we have to group above to make use of a limit 1.
		-- A loop must be used because it is not possible to store multiple rows in a variable.
		-- So here we obtain all the jobs related to the pipe_job_id and process we are ready to pick up.
		FOR a_job in select * from job_queue where 
				pipe_job_id = job_list.pipe_job_id and
				job_assign_Process_uuid is null and
				job_assign_process_name = $3 and
			    job_assign_process_version = $4
		loop
			-- We are using array appending here:
			my_jobs := my_jobs || a_job;
			-- 'pick up' record by record:
			update job_queue set 
		    	job_assign_Process_uuid = $1, 
		    	job_assign_timestamp = current_timestamp where
		    	job_id = a_job.job_id and job_assign_Process_uuid is null;
		end loop;
	else
		-- Finds a single job
		select * into a_job from job_queue where
			(job_assign_Process_uuid = '')  is not false and  -- True for '' and NULL, accepting '' makes it easier (and less hidden) to make a job available again.
			job_assign_process_name = $3 and
		    job_assign_process_version = $4
		    order by job_priority, job_create_timestamp limit 1 for update;

		-- RETURNs with 'No job found' if nothing found.
		if not found then return; end if;
		my_jobs := my_jobs || a_job;

		update job_queue set 
		    	job_assign_Process_uuid = $1, 
		    	job_assign_timestamp = current_timestamp where
		    	job_id = a_job.job_id and job_assign_Process_uuid is null;
	end if;

	-- Set process heartbeat bussy to TRUE (for now, this is nothing more than an indication).
	update process_heartbeats set process_bussy = true where Process_uuid = $1;
	
	-- the updates performed within this operation are not included in the content of the json that is returned.
	output := array_to_json(my_jobs)::text;

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
-- truncate job_queue; truncate pipe_job_queue;

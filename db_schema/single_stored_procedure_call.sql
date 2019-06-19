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
-- (Rewrote al things that depended on this view)
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
   (1, 'example_pipe',          '1.0.5',   'examples',        1), 
   (2, 'example_pipe_followup', '99.3.88', 'post_operations', 2);
insert into pipeline_processes (pipe_id, process_name, process_version, process_order) values
   (1, 'second_process', '1.5.2', 2),
   (1, 'first_process',  '1.0.0', 1),
   (1, 'third_process',  '1.0.0', 3);
insert into pipeline_processes (pipe_id, process_name, process_version, process_order, process_configuration) values
   (2, '2_fourth_process', '1.9.2', 1, '{"configuration": ""}'),
   (2, '2_fifth_process',  '2.2.0', 2, '{"configuration": "fifth process configuration"}'),
   (2, '2_sixed_process',  '5.3.0', 3, '{"configuration": ""}');

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
    pipe_job_finished          BOOL default false
);
comment on column pipe_job_Queue.pipe_job_Priority is 'Jobs are sorted based on this priority. Defaults to 100, range of smallint.';

-- Job Queue table
CREATE TABLE Job_Queue (
    Job_Id                     SERIAL primary key,
    pipe_job_Id                INT,
    Pipe_Id                    INT,
    job_Payload                JSONB default '{}',     -- A binairy representation of the inserted JSON object
    job_set_size               INT default 1,          -- If 1, will be picked up if done, if x (>1), x jobs must be created and unassigned/unfinished to be picked up all at once.
    job_Priority               smallint default 100,   -- The priority on which jobs are sorted.
    job_finished               BOOL default null,      -- with null, we could use 'false' as 'aborted' or 'crashed'.
    Job_Create_Timestamp       TIMESTAMPTZ default current_timestamp,
    Job_Finished_Timestamp     TIMESTAMPTZ default current_timestamp,
    Job_Create_Process_uuid    VARCHAR(12) not null,
    Job_Create_Process_Name    VARCHAR(50) not null,
    Job_Create_Process_Version VARCHAR(10) not null,
    Job_Assign_Timestamp       TIMESTAMPTZ,
    Job_Assign_Process_uuid    VARCHAR(12),
    Job_Assign_Process_Name    VARCHAR(50),
    Job_Assign_Process_Version VARCHAR(10),
    Job_Assign_Process_Config  JSONB default '{}'
);
comment on column Job_Queue.job_Priority is 'Jobs are sorted based on this priority. Inherits from pipe_job_Queue. Defaults to 100, range of smallint.';
comment on column Job_Queue.job_set_size is 'The priority on which jobs are sorted. Defaults to 100.';

-- Create Jobs failed  (conceptual)
--create table Jobs_Failed (
--    job_failed_id         SERIAL primary key,
--    Job_Id                INT,
--    pipe_job_Id            INT,
--    Error_Message         VARCHAR(255)
--);


-------------------------------------------------------------------------------------
            -- stored procedures --
-------------------------------------------------------------------------------------


-- Create initial job (this is not performed using a Stored Procedure)
-- The 'Create_job' procedure that follows below covers only the creation of jobs by processes that are processing a job.

call create_entry_job(99, 1);  -- request, pipe_id
call create_entry_job(100, 2);  -- request, pipe_id
call create_entry_job(101, 1);  -- request, pipe_id


-- Create entry Job.
-- pipe_job_Id, pipe_id
create or replace
PROCEDURE create_entry_job(INT, INT) as $$
declare
	starting_process  pipeline_processes%ROWTYPE; 
begin
	-- Find first process of this pipeline:
	select * into starting_process from pipeline_processes where pipe_Id = $2 and process_order = 1;

	if not found then RAISE EXCEPTION 'McR Error! No process with process_order 1 could be found for the pipe `%`.', $2; end if;

	insert into job_queue(pipe_job_Id, Pipe_Id, job_Payload, job_create_Process_uuid, Job_Create_Process_Name, Job_Create_Process_Version,
			Job_Assign_Process_Name, Job_Assign_Process_Version, Job_Assign_Process_config)
	values ($1, $2, '{}', '', '', '', 
			starting_process.process_name, starting_process.process_version, starting_process.process_configuration);
end;
$$ language plpgsql



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

select get_next_process(2, '2_fifth_process', '2.2.0');


-- Create Job.
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
	commit;

	-- Obtain previous job:
	select * into old_job from job_queue where job_id = $1;
	
	-- Find process that needs to follow-up on this job:
	select * into next_process from get_next_process(old_job.pipe_id, old_job.Job_assign_Process_Name, old_job.Job_assign_Process_Version);
   
    -- If all is well, create the new job.
	insert into
		job_queue(pipe_job_Id, Pipe_Id, job_Payload, job_set_size, job_create_Process_uuid, Job_Create_Process_Name, Job_Create_Process_Version,
				  Job_Assign_Process_Name, Job_Assign_Process_Version, Job_Assign_Process_config)
	values (old_job.pipe_job_Id,  old_job.pipe_id,  $3,  $2, old_job.job_assign_process_uuid,  old_job.job_assign_process_name,  old_job.job_assign_process_version,
			next_process.process_name,  next_process.process_version,  next_process.process_configuration);

end;
$$ language plpgsql;

-- job id,  set size,   Payload
CALL create_job(2, 1, '{}');
CALL create_job(1, 2, '{}');
CALL create_job(1, 1, '{}');


------------
--- I could have created a (set or) batch  gather job, which is then only created when all other jobs are also finished
--- But where would I then leave the payload of all the jobs that were not 'the last job' and did not have the priveledge to create this job...
--- To solve this problem I will work with a 'job_set_size' which indicates how many jobs make a 'single input' when they are all untaken/unfinished.
------------

-- Create Job. Fired many times, only succeeds when last job is finished.
-- job_id
--create or replace PROCEDURE create_batch_combine_job(INT)
--as $$
--declare
--	old_job         job_queue%ROWTYPE; 
--	all_jobs        job_queue%ROWTYPE; 
--	next_process    pipeline_processes%ROWTYPE; 
--begin
--	-- Update just executed job:
--	update job_queue set job_finished = true where job_id = $1;
--	commit;
--
--	-- Obtain my job info:
--	select * into old_job from job_queue where job_id = $1;
--	
--	-- Obtain all batch jobs (can also be one).
--	select * into all_jobs from job_queue
--		where pipe_job_Id = old_job.pipe_job_Id
--		and pipe_id = old_job.pipe_id
--		and job_assign_process_name = old_job.job_assign_process_name;
--	
--	-- If not all finished, do nothing!!:
--	-- (bool_and  is some kind of 'all' function)
--	if all_jobs is null or 
--			not bool_and(all_jobs.job_finished) then
--		return;
--	end if;
--
--	-- Find process that needs to follow-up on this job:
--	select get_next_process(old_job.pipe_id, old_job.Job_assign_Process_Name, 
--		old_job.Job_assign_Process_Version) into next_process;
----	select * into next_process from pipeline_processes
----	       where pipe_Id = old_job.pipe_id 
----	       and process_order = (
----	       		select process_order + 1 from pipeline_processes
----		       		where pipe_Id = old_job.pipe_id
----		       		and   process_name    = old_job.Job_assign_Process_Name
----	    	   		and   process_version = old_job.Job_assign_Process_Version);
--
--    -- If all is well, create the new job.
--	insert into
--		job_queue(pipe_job_Id, Pipe_Id, job_Payload, job_create_Process_uuid, Job_Create_Process_Name, Job_Create_Process_Version,
--		Job_Assign_Process_Name, Job_Assign_Process_Version, Job_Assign_Process_config)
--	values (old_job.pipe_job_Id,  old_job.pipe_id,  row_to_json(all_jobs),  old_job.job_assign_process_uuid,  old_job.job_assign_process_name,  old_job.job_assign_process_version, 
--			next_process.process_name,  next_process.process_version,  next_process.process_configuration);
--
--end;
--$$ language plpgsql;
--
--
--call find_batch_combine_job(5);


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



-- Creating a (mini table) type that stores 3 variables. Makes passing trough data easier.
CREATE TYPE job_batch_thing AS (pipe_job_id int, all_ready bool);   -- drop type job_batch_thing;

-- Find fitting job and assign it!!
-- PROCEDURE Provides flexible input, no return value, so can use notification, supports transactions.
-- FUNCTION  Provides flexible input, 1 return value,  no notification necessary, does not support transactions. 
-- TRIGGER   no flexible input, no return value, so can use notification, does not support transactions.

-- Since we are working within a single transaction
-- Trying 'function' approach: 
-- UUID, server_name, process_name, process_version
CREATE OR REPLACE FUNCTION find_job(in VARCHAR(12), in VARCHAR(50), in VARCHAR(50), in VARCHAR(10),
                                    out output varchar)
returns varchar AS $$
declare
    job_list  job_batch_thing%ROWTYPE;
    my_jobs   job_queue%ROWTYPE;
begin
	call send_heartbeat($1, $2, $3, $4);
		
	-- If kill_switch is set, kill app:
	if (select Process_Kill_switch from process_heartbeats where process_uuid = $1) = True then
		output := 'kill';
		return;
	end if;

	-- This following query leaves out the 'pipe_id', this does not matter for a container that takes a job.
	-- Find a single or batch of jobs that comes in a set, the size of `job_set_size`.
	-- take only 1 set when ordered on priority
	select pipe_job_id, (count(pipe_job_id) = max(job_set_size)) as all_ready
		into job_list from job_queue where 
		job_assign_Process_uuid is null and
		job_assign_process_name =  $3 and
	    job_assign_process_version = $4
	   	group by pipe_job_id
	   	order by all_ready desc,
	   		min(job_priority),
	   		max(job_create_timestamp)
	    limit 1;
	   
	-- build-in: 'found', checks if 'previous query' returned any result.
	if not found or not (job_list).all_ready then
		output:= 'No job found';
		return;
	end if;

	-- This operation must happen seperately because we have to group above to make use of a limit 1.
	-- So here we obtain all the jobs related to the pipe_job_id and process we are ready to pick up.
	select * into my_jobs from job_queue where 
		pipe_job_id = (job_list).pipe_job_id and
		job_assign_Process_uuid is null and
		job_assign_process_name =  $3 and
	    job_assign_process_version = $4 for update;

	update job_queue set 
    	job_assign_Process_uuid = $1, 
    	job_assign_timestamp = current_timestamp where
    	job_id in (my_jobs.job_id) and job_assign_Process_uuid is null;
    
	-- Set process heartbeat bussy to TRUE (for now, this is nothing more than an indication).
	update process_heartbeats set process_bussy = true where Process_uuid = $1;
	
	-- The 'job_queue' is queried again to obtain the latest and just updated job content.
	select * into my_jobs from job_queue where job_id in (my_jobs.job_id);
	output := row_to_json(my_jobs)::text;
	return;

END;
$$ LANGUAGE plpgsql;

	   
-- UUID, server_name, process_name, process_version
select find_job('ldfjl', 'sdlfkj', 'second_process', '.0.0');
call create_job(2, '{}');

-- START TRANSACTION ISOLATION LEVEL SERIALIZABLE
 
--declare
--	old_job         job_queue%ROWTYPE; 
--	all_jobs        job_queue%ROWTYPE; 
--	next_process    pipeline_processes%ROWTYPE; 
--begin
--	-- Update just executed job:
--	update job_queue set job_finished = true where job_id = $1;
--	commit;
--
--	-- Obtain my job info:
--	select * into old_job from job_queue where job_id = $1;
--	
--	-- Obtain all batch jobs (can also be one).
--	select * into all_jobs from job_queue
--		where pipe_job_Id = old_job.pipe_job_Id
--		and pipe_id = old_job.pipe_id
--		and job_assign_process_name = old_job.job_assign_process_name;
--	
--	-- If not all finished, do nothing!!:
--	-- (bool_and  is some kind of 'all' function)
--	if all_jobs is null or 
--			not bool_and(all_jobs.job_finished) then
--		return;
--	end if;

--
---- Since we are working within a single transaction
---- Trying 'function' approach: 
---- UUID, server_name, process_name, process_version
--CREATE OR REPLACE FUNCTION find_batch_job(in VARCHAR(12), in VARCHAR(50), in VARCHAR(50), in VARCHAR(10),
--                                    out output varchar)
--returns varchar AS $$
--declare
--    all_jobs  job_queue%ROWTYPE; 
--begin
--	call send_heartbeat($1, $2, $3, $4);
--	
--	-- If kill_switch is set, kill app:
--	--select Process_Kill_switch into  from process_heartbeats where process_uuid = $1;
--	--if check = True then
--	if (select Process_Kill_switch from process_heartbeats where process_uuid = $1) = True then
--		output := 'kill';
--		return;
--	end if;
--
--	-- Check if there is a task available for me:
--	-- This check leaves out the 'pipe_id', because this does not matter for a container that takes a job.
--	select pipe_job_Id into my_job from job_queue where 
--		job_assign_Process_uuid is null
--		group by job_assign_Process_uuid;
--	
--	select * into my_job from job_queue where
--		job_assign_Process_uuid is null and
--		job_assign_process_name = $3 and
--	    job_assign_process_version = $4
--	    order by job_priority, job_create_timestamp limit 1 for update;
--	
--	update job_queue set 
--    	job_assign_Process_uuid = $1, 
--    	job_assign_timestamp = current_timestamp where
--    	job_id = my_job.job_id and job_assign_Process_uuid is null;
--    
--	-- Set process heartbeat bussy to TRUE (for now, this is nothing more than an indication).
--	update process_heartbeats set process_bussy = true where Process_uuid = $1;
--	-- build-in: 'found', checks if 'previous query' returned any result.
--	
--	if my_job IS null then
--		output := 'No job found';
--		return;
--	end if;
--	
--	output := row_to_json(all_jobs)::text;
--	return;
--
--END;
--$$ LANGUAGE plpgsql;

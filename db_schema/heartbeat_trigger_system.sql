create user test_user with encrypted password 'test_user';
------------------------------------
-- create new db
create database heartbeat_notify_job_queue;
ALTER database heartbeat_notify_job_queue OWNER TO test_user;
GRANT all ON DATABASE heartbeat_notify_job_queue TO test_user;



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
ALTER TABLE public.pipeline_process_order OWNER TO siete;
GRANT ALL ON TABLE public.pipeline_process_order TO siete;



-- Insert some values
insert into Pipelines (pipe_id, pipe_name, pipe_version, pipe_type, pipe_order) values 
   (1, 'example_pipe',          '1.0.5',   'examples',        1), 
   (2, 'example_pipe_followup', '99.3.88', 'post_operations', 2);
insert into pipeline_processes values
   (1, 'second_process', '1.5.2', 2, '{}'),
   (1, 'first_process',  '1.0.0', 1, '{}'),
   (1, 'third_process',  '1.0.0', 3, '{}');

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

-- Job Queue table 
CREATE TABLE Job_Queue (
    Job_Id                     SERIAL primary key,
    Request_Id                 INT,
    Pipe_Id                    INT,
    job_Payload                JSONB default '{}',   -- A binairy representation of the inserted JSON object
    job_finished               BOOL default false,
    Job_Create_Timestamp       TIMESTAMPTZ default current_timestamp,
    Job_Create_Process_uuid    VARCHAR(12) not null,
    Job_Create_Process_Name    VARCHAR(50) not null,
    Job_Create_Process_Version VARCHAR(10) not null,
    Job_Assign_Timestamp       TIMESTAMPTZ,
    Job_Assign_Process_uuid    VARCHAR(12),
    Job_Assign_Process_Name    VARCHAR(50),
    Job_Assign_Process_Version VARCHAR(10),
    Job_Assign_Process_Config  JSONB default '{}'
);

-- Create Jobs failed
create table Jobs_Failed (
    job_failed_id         SERIAL primary key,
    Job_Id                INT,
    Request_Id            INT,
    Error_Message         VARCHAR(255)
);


-- Inserts a heartbeat of a containerHash or updates it.
create or replace
PROCEDURE send_heartbeat(VARCHAR(12), VARCHAR(50), VARCHAR(50), VARCHAR(10)) as $$
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
$$ language plpgsql

-- Create initial job (this is not performed using a Stored Procedure)
-- The 'Create_job' procedure that follows below covers only the creation of jobs by processes that are processing a job.
INSERT INTO public.job_queue
(request_id, pipe_id, job_payload, job_create_Process_uuid, job_create_process_name, job_create_process_version, job_assign_timestamp, job_assign_Process_uuid, job_assign_process_name, job_assign_process_version)
VALUES(1, 1, '{"mypayload": "woooow"}', 'TheWebsite', 'MyMcroberts', '1.7.3', NULL, NULL, 'first_process', '1.0.0');


-- Create entry Job.
-- request_id, pipe_id
--create or replace
--PROCEDURE create_entry_job(INT, INT) as $$
--declare
--	my_job          job_queue%ROWTYPE; 
--	next_process    pipeline_process_order%ROWTYPE; 
--	process_config  pipeline_processes.process_configuration%TYPE; 
--begin
--	INSERT INTO public.job_queue
--(request_id, pipe_id, job_payload, job_create_Process_uuid, job_create_process_name, job_create_process_version, job_assign_timestamp, job_assign_Process_uuid, job_assign_process_name, job_assign_process_version)
--VALUES(1, 1, '', 'TheWebsite', 'MyMcroberts', '1.7.3', NULL, NULL, 'first_process', '1.0.0');
--
--	-- Obtain previous job:
--	select * into my_job where job_id = $1
--	-- Update previous job:
--	update job_queue set job_finished = true where job_id = $1
--	
--	-- Find process that needs to process this job:
--	select * into next_process
--	       from pipeline_process_order 
--	       where pipe_Id              = my_job.pipe_id 
--	       and   prev_process_name    = my_job.Job_Create_Process_Name
--	       and   prev_process_version = my_job.Job_Create_Process_Version;
--	
--	-- SOME ERROR HANDLING
--	-- Check if a followup process was found.
--	-- If not, add 'jobs_failed' entry and throw exception back to application.
--	if not found then
--		insert into
--			jobs_failed(job_id, Request_Id, error_message) values 
--		    	(0, $1, 'No process found for pipe `' || $2::text || '` process name `' || $5 || '` process version `' || $6 || '` in view `pipeline_process_order`.');
--		    -- The exception will cause a rollback of this stored procedure. Therefore we need to commit.
--		    commit;
--		RAISE EXCEPTION 'McR Error! No process found for pipe `%` process name `%` process version `%` in view `pipeline_process_order`.', $2, $5, $6;
--	end if;
--
--    -- Get configuration
--    select process_configuration into process_config from pipeline_processes where 
--    	pipe_id = next_process.pipe_id and
--    	process_name = next_process.process_name and
--    	process_version = next_process.process_version;
--    
--    -- If all is well, create the new job.
--	insert into
--		job_queue(Request_Id, Pipe_Id, job_Payload, job_create_Process_uuid, Job_Create_Process_Name, Job_Create_Process_Version, Job_Assign_Process_Name, Job_Assign_Process_Version, Job_Assign_Process_config)
--	values ($1, $2, $3, $4, $5, $6, next_process.process_name, next_process.process_version, process_config);
--
--end;
--$$ language plpgsql


-- Create Job.
-- job_id, Payload
create or replace
PROCEDURE create_job(INT, JSONB) as $$
declare
	my_job          job_queue%ROWTYPE; 
	next_process    pipeline_process_order%ROWTYPE; 
	process_config  pipeline_processes.process_configuration%TYPE; 
begin
	-- Obtain previous job:
	select * into my_job where job_id = $1
	-- Update previous job:
	update job_queue set job_finished = true where job_id = $1
	
	-- Find process that needs to process this job:
	select * into next_process
	       from pipeline_process_order 
	       where pipe_Id              = my_job.pipe_id 
	       and   prev_process_name    = my_job.Job_Create_Process_Name
	       and   prev_process_version = my_job.Job_Create_Process_Version;
	
	-- SOME ERROR HANDLING
	-- Check if a followup process was found.
	-- If not, add 'jobs_failed' entry and throw exception back to application.
	if not found then
		insert into
			jobs_failed(job_id, Request_Id, error_message) values 
		    	(0, $1, 'No process found for pipe `' || $2::text || '` process name `' || $5 || '` process version `' || $6 || '` in view `pipeline_process_order`.');
		    -- The exception will cause a rollback of this stored procedure. Therefore we need to commit.
		    commit;
		RAISE EXCEPTION 'McR Error! No process found for pipe `%` process name `%` process version `%` in view `pipeline_process_order`.', $2, $5, $6;
	end if;

    -- Get configuration
    select process_configuration into process_config from pipeline_processes where 
    	pipe_id = next_process.pipe_id and
    	process_name = next_process.process_name and
    	process_version = next_process.process_version;
    
    -- If all is well, create the new job.
	insert into
		job_queue(Request_Id, Pipe_Id, job_Payload, job_create_Process_uuid, Job_Create_Process_Name, Job_Create_Process_Version, Job_Assign_Process_Name, Job_Assign_Process_Version, Job_Assign_Process_config)
	values ($1, $2, $3, $4, $5, $6, next_process.process_name, next_process.process_version, process_config);

end;
$$ language plpgsql


-- PERFORM 'Create_job'
-- Request Id, Pipe Id,  Payload,  containerhash,  my Process Name,  my Process Version
CALL create_job(1, 1,    '{}',     'conthash',     'third_process',  '1.0.0');
CALL create_job(1, 1,    '{"your task": "Now do a shitload of work"}',     'conthash',     'first_process',  '1.0.0');
CALL create_job(1, 1,    '{}',     'conthash',     'second_process',  '1.5.3');
CALL create_job(1, 1,    '{}',     'conthash',     'first_process',  '1.0.0');
CALL create_job(1, 1,    '{}',     'conthash',     'first_process',  '1.0.0');
CALL create_job(1, 1,    '{}',     'conthash',     'first_process',  '1.0.0');
CALL create_job(1, 1,    '{}',     'conthash',     'first_process',  '1.0.0');
CALL create_job(1, 1,    '{}',     'conthash',     'second_process',  '1.5.3');
CALL create_job(1, 1,    '{}',     'conthash',     'first_process',  '1.0.0');


-- Take Job.
-- job_id, Process_uuid
create or replace
PROCEDURE take_job(int, VARCHAR(12)) as $$
begin
    -- Update job that's picked up:
    update job_queue set 
    	job_assign_Process_uuid = $2, 
    	job_assign_timestamp = current_timestamp where
    	job_id = $1 and job_assign_Process_uuid is null;
    
	-- Set process heartbeat bussy to TRUE (for now, this is nothing more than an indication).
	update process_heartbeats set process_bussy = true where Process_uuid = $2;
end;
$$ language plpgsql



-- manual notify
notify channel_af20f3dca1ae, 'kill';




-- Find fitting job and assign it!!
-- No input arguments, since it is used as trigger function.
-- The value `new.xxx` is the inserted/updated row that launched the trigger.
CREATE OR REPLACE FUNCTION notify_fitting_job()
    RETURNS trigger
    AS $$
declare
    channel  varchar(50);
    my_job   job_queue%ROWTYPE;
begin
	-- Could be any UUID, but lets use a containerHash, since that's somewhat informative.
	channel := 'channel_' || LOWER(NEW.Process_uuid);
	
	-- If kill_switch is set, kill app:
	if NEW.Process_Kill_switch = True then
	    PERFORM pg_notify(channel, 'kill');
	    return null;
	end if;

	-- Check if there is a task available for me:
	-- This check leaves out the 'pipe_id', because this does not matter for a container.
	select * into my_job from job_queue where
		job_assign_Process_uuid is null and
		job_assign_process_name = NEW.process_name and
	    job_assign_process_version = NEW.process_version
	    order by job_create_timestamp limit 1;
	
	-- build-in: 'found', checks if 'previous query' returned any result.
	if not found then
		PERFORM pg_notify(channel, 'No job found');
	   	return null;
	end if;

	-- Assign job:
	CALL take_job(my_job.job_id, NEW.Process_uuid);
	
	-- Send notification over channel 'channel_h53jkh4' with message '{payload: 'abklj', configuration: 'ldfj'}'
    PERFORM pg_notify(channel, row_to_json(my_job)::text);  -- We are just sending the complete Job!! so awesome...
	
    return null;
END;
$$ LANGUAGE plpgsql;


CREATE TRIGGER notify_fitting_job
  AFTER insert or UPDATE of last_beat_Timestamp ON Process_Heartbeats
  FOR EACH ROW
  EXECUTE PROCEDURE notify_fitting_job();
 
-- START TRANSACTION ISOLATION LEVEL SERIALIZABLE
 
-- DROP TRIGGER IF EXISTS notify_fitting_job ON Process_Heartbeats;
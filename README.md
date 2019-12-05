# job_queue_PostgreSQL
This repository did include 2 proof of concepts that shows how to create a job_queue database with PostgreSQL (up till commit bc5047da).
After that, I continued with a single concept because it proved better and the PostgreSQL notify/listen construct (where the other concept was based on) did not prove valuable.

In general, every pipeline (stored in `pipelines`) defines itself by a specific set of processes (stored in `pipeline_processes`). Processes might be reused (recycled) among pipeline definitions. If process 'A' of version 1.0.0 is used in pipe 'my_pipe' and also in 'my_sec_pipe', there is only need for one 'A' process of version '1.0.0' to run somewhere on some server to cover all the jobs from both pipelines. Jobs for pipelines are stored in the `pipe_job_queue`. When a pipe_job is added there, it creates an initial job in the (process interacting) `job_queue`. It is possible that pipes only defer by one 'process' (or module/package/service) in their pipe definition. But it is also possible that none of the processes are the same, where the pipeline is likely to perform a completely different operation. In this repo a dummy process is provided by the name `example_process.py` which is created to be able to run with a banner with a variaty of names and versions. A process only interacts with the job_queue table via PostgreSQL stored procedures. The different procedures, the heart of the job_queue workings, can be found in `db_schema/job_queue_database_schema.sql`.

To eliminate the need for a 'service discovery feature', every process performs a `send_heardbeat` operation which tells the database that the process is still running and that it is ready to receive some job. To receive jobs from the database, the process calls a stored procedure in the database and provides his process name and process version. The PostgreSQL procedure performs the heartbeat operation and checks if a `job_queue` job is available. The procedure can respond in multiple ways:
* `no job found` - Which tells the process to try again in a few seconds. The only effect that the process call had was to update the heartbeat.
* `kill` - This tells the process to get rid of itself. A clean way to guarantee that the process is terminated while it is not performing an operation. If it should kill itself can be configured in the `heartbeat` table, a 'true' for the process_kill column will result in a `kill` notification.
* `Retry, I lost the job race` - Also tells us to try again, but this time there was a job, but another process with the same name and version tried to pick it up at the same time.
* `{lkflk....dlfjl}` - a full fletched "JSON" with the complete Job database entry including the payload. When this is received, a job is found and assigned to ‘me’ and work is to be done.

Included functionallity in this job queue implementation are:
- job priorities
- processes that create many jobs (which will run in parallel)
- processes that get assigned 'many jobs' their outcomes, but only when they are all finished, and will receive a payload containing all those jobs their payloads.
- multi order pipelines (if all order 1 `pipe_job_queue` operations are finished for a specific request, the `pipe_job_queue` order 2 jobs will be initiated by creating their first process job in the `job_queue`)
- if the last job (or the last process) of a pipeline is finished, instead of making a new job, it will finish the job and the pipe_job using `finish_pipe` procedure.

The term 'pipeline' refers to the flow from process A to B to C, and does not refer to a pipeline architecture, which this concept clearly does not promote. In the example data included in the `sql` scripts you will find some names for the fictional processes that are used. To help understand how the processes (and their configuration in the `pipelines` and `pipeline_processes` tables) are acting on eachother, I will explain what the individual processes are doing:
- `assigner`: Gathering metadata and when finished, will launch a bunch (set) of other jobs ->
- `classification`: (many jobs in parallel) A resources intensive operation which is, thanks to the previous process, properly spread over multiple processes ->
- `merging_results`: Gathering the outcomes of the `classification` jobs and cleaning them up. This process then passes the combined results through to the next process -> 
- `uploader`: Gathering the outcomes of the `classification` jobs and rounding up. This process fires of the `finish_pipe` stored procedure which will update the job and pipe_job 'finished' flag to `true`, which will then potentially trigger the next order pipe_job.

## Examples:
(I will leave installing python 3.x/PostgreSQL and making a 'test_user' for your local database up to you)

To execute the example, run the complete database script `.\db_schema\job_queue_database_schema.sql`. Then there are 2 ways of setting it up:
1. Run `docker-compose up` to create an environment with one container, the 'assigner', which will only pick up initial pipe_jobs but will make use of `fluentd`, `elasticsearch` and `Kibana` to create a nice logging experience.
2. Run `example_process_launcher_in_docker.ps1` to start multiple containers. (I configured logging there, but I remember I didn't get it to work yet).

The one or many processes will pick up the jobs which were created by the `pipe_job_queue` table in the `job_queue`. Everything that follows should happen automatically till all four `pipe_job_queue` pipe_job's are finished and many jobs are created and processed. To run the example again, run the `truncate` operation commented at the bottom of the sql script and run the `insert` query right above it. This will redo the complete process.

NOTE: Didn't test both docker examples, but am committing them now as good as possible. Also changed name of 2 files from `single_stored_procedure_call.sql` to `job_queue_database_schema.sql` and `single_call_job_queue.py` to `example_process.py`.

# Some quick notes related to the concept its behaviour:

- All timestamps are server timestamps including a timezone.
- All order 0 and 1 pipe_jobs will result in a `job_queue` job automatically. Other order pipe_jobs can only be fired by the `finish_pipe` procedure.
- When there is no pipe_job of order 1 created for a request, it is silently not picked up. Creating a pipe_job directly only adds a job in the job_queue for this pipe_job when of order 0 or 1.
- Pipe job order numbers must follow up with an increment of 1. If a gap exists between pipe_job order ID’s, the next pipe_job is not picked up. This can be fixed by adding the missing pipe_job (with the correct order) and manually firing the stored procedure: `create_entry_job(<pipe_job_id>, <pipe_id>, <priority>, row_to_json(<complete pipe_job entry>))`.
- `Finish_pipe` marks (all) parent job(s) as finished, adds finished timestamp and marks the pipe_job as finished
- (committing halfway a function is not possible) The heartbeat is ‘rolled back’ when the ‘find_job’ process fails somewhere (note that stopping due to a race condition is not a failure).
- For jobs with a job_Create_Set_Elements value of NULL or ‘’, this value will be ignored in the Job choosing process. It is considered a single Job, with 1 parent and 1 consumer.
- Priority is currently sorted so that lower numbers are processed first. The highest priority (the lowest number) of a batch determines the priority of a set of jobs (but in general those are equal because priority is determined on pipe_job level).
- If I can find a way to include the job id in the job itself when pipe_job callback is ran, I can probably support multiple equal processes in a single pipeline (e.g. A -> B -> C -> A -> D). This would increase complexity, as A -> B -> A ->… would still not be possible.
- First job will never be picked up with the ‘obtain multiple jobs’ flag of the `find_jobs` function.
- If the `create_jobs` procedure is rolled back, it potentially leaves gaps for the primary key values in the Job_queque that are 'reserved' (if I understand correctly) due to the 'RETURNING' operation (https://www.postgresql.org/docs/9.5/dml-returning.html).
- for the `create_jobs` procedure, the job_payload's must be provided in a JSON array object (so always caught in square brackets in the sql call). E.g. ‘[{"my_job": "38 None", "parent_payload": 5}]’. Then, for every element in the json array, a job is created in the database. So for the payload ‘[{"my_job": "38 None", "parent_payload": 5}, {"my_job": "40 None", "parent_payload": 999}]’, 2 jobs will be created, with respectively the payloads ‘{"my_job": "38 None", "parent_payload": 5}’ and ‘{"my_job": "40 None", "parent_payload": 999}’
- Order 0 pipe line jobs will create a job_queue entry but will not, when finished, fire the next pipe_job. This is build in to make it possible to add pipeline jobs which are triggered (/added) by an external instance. An order 0 pipeline job will result in a job_queue job immediately, but will not fire the order 1 pipeline job afterwards. (It is conceptual, there is a high chance this feature will not be used. It could potentially help support running pipe_jobs which have external dependencies, where the external dependency can make it available).
- If two pipe_job order 1 jobs are finished at the same time, it could theoretically happen that both transactions find the other unfinished pipe_job and do not decide to fire off the order 2 pipe_job's. This race condition is not covered and should be fore production! (we could perform this operation that is ran only once per pipeline in serializable mode...)

# Docker run instructions: 

After updates to the code, make sure the `requirements.txt` is updated using `pip freeze > requirements.txt`.

Build the container:
	`docker build -t multifunctionalprocess --build-arg PROCESS_NAME=first_process --build-arg PROCESS_VERSION=1.9.2 .`

If you are running your postgreSQL database locally, make sure the postgress configuration (C:\Program Files\PostgreSQL\11\data\postgresql.conf)
- allowes all IP addresses to connect to the DB by setting `listen_addresses = '*'`

In another configuration file (same folder: C:\Program Files\PostgreSQL\11\data\pg_hba.conf):
- add the row `host    all             all             host.docker.internal    md5`.
-- The 'host.docker.internal' refers to your localhost IP and is automatically created when installing docker. It can be used inside or outside the container context to connect to the local host (host where the docker deamon runs).

Create and fill the file .env (the layout will probably look terrible due to the backticks. These must be included btw):
- Run the following in powershell for a good template: echo "# PostgreSQL database credentials`nPGHOST=host.docker.internal`nPGUSER=test_user`nPGPASSWORD=test_user`nPGDATABASE=job_queue_database`n" > .env`

Start the container:
	`docker run -it --env-file=.env multifunctionalprocess`
When you would like another process name and version than the default, run:
	`docker run -it --env PROCESS_NAME=second_process --env PROCESS_VERSION=1.0.0 --env-file=.env multifunctionalprocess`


# Debugging Elasticsearch:
Elasticsearch can be talked to through a restfull API. Indexes can be deleted in powershell by running the following (replace 'myindexhere'):
`Invoke-RestMethod -Uri http://localhost:9200/myindexhere -Method delete -ContentType 'application/json'`

Checking shard health (no idea actually what inside this provides). This link can be used in a browser:
`http://localhost:9200/_cluster/health/`
`http://localhost:9200/_cluster/health/?level=shards`



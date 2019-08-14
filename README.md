# job_queue_PostgreSQL
This repository includes 2 proof of concepts that show how to create a job_queue database with PostgreSQL.

In general, every pipeline (stored in `pipelines`) defines itself by a specific set of processes (stored in `pipeline_processes`). Processes might be reused (recycled) among pipeline definitions. If process 'A' of version 1.0.0 is used in pipe 'my_pipe' and also in 'my_sec_pipe', there is only need for one 'A' process of version '1.0.0' to run somewhere on some server to cover all the jobs from both pipelines. Jobs for pipelines are stored in `pipe_job_queue`, which creates initial jobs in the (process interacting) `job_queue`. It is possible that pipes only defer by one 'process' (or module/package/service) in their pipe definition. But it is also possible that none of the processes are the same, where the pipeline is likely to perform a completely different operation.

# First POC: Notify Listen job queue
- `notify_listen_job_queue.py`
- `heartbeat_trigger_system.sql`

The second POC contains many more features, but the only real different element between the concepts is the 'find_job' operation.

To eliminate the need for a service discovery feature, every process performs a `send_heardbeat` operation which tells the database that the process is still running. To receive jobs from the database, the process first starts to listen on a channel consisting of a universally unique id (uuid) which it also shares when sending a heartbeat. When listening, the process sends a heartbeat. This action triggers a job find operation which can then return 'No job found', or a payload for a job in a `NOTIFY` operation.

If the `process_heartbeats.process_kill_switch` flag is set to TRUE, a response with the message 'kill' is returned.
The process is configured to kill itself for a 'kill' response, to wait a second and send another heartbeat for a 'No job found' response and to print 'SUCCESS' and the payload content when a job was found and the payload was returned by PostgreSQL.
When a valid payload was received, the process will create a new job (the next job in line, see the `pipeline_processes` table). This new job is then picked up by the second process (depending on the process name and version it has) and so on.

# Second POC: Single call job queue
- `single_call_job_queue.py`
- `single_stored_procedure_call.sql`
- `start_single_call_example_processes.ps1` (example material)

Instead of using the PostgreSQL `NOTIFY/LISTEN` construct, we can also just create a database function (a stored procedure kind of construct which can return a value, in our case a `varchar`). This function, called from a process, returns the same kind of responses that were explained in the first POC.

This concept is expanded to include:
- job priorities
- processes that create many jobs (which will run in parallel)
- processes that get assigned 'many jobs' their outcomes and will receive a payload containing all those jobs in a json structure.
- multi order pipelines (if all order 1 `pipe_job_queue` operations are finished for a specific request, the `pipe_job_queue` order 2 jobs will be initiated by creating their first process job)
- if the last 'job_queue job'/process of a pipeline is finished, it will finish it's corresponding `pipe_job_queue` job.

So it is clearly more feature rich. Additionally it prints much smaller strings to be able to run many processes for an example run. Also no string is printed when PostgreSQL `find_job` function calls are terminated because of the 'serializable' approach which I (had to?) use (the serializable property is forced in the python script).

The term 'pipeline' refers to the flow from process A to B to C, and does not refer to a pipeline architecture, which this concept clearly does not promote. In the example data included in the `sql` scripts you will find some names for the fictional processes that are used. To help understand how the processes (and their configuration in the `pipelines` and `pipeline_processes` tables) are acting on eachother, I will explain what the individual processes are doing:
- `assigner`: Gathering metadata and when finished, will launch a bunch (set) of other jobs ->
- `classification`: (many jobs in parallel) A resources intensive operation which is, thanks to the previous process, properly spread over multiple processes ->
- `merging_results`: Gathering the outcomes of the `classification` jobs and cleaning them up. This process then passes the combined results through to the next process -> 
- `uploader`: Gathering the outcomes of the `classification` jobs and rounding up. This process fires of the `finish_pipe` stored procedure which will update the job and pipe_job 'finished' flag to `true`, which will then potentially trigger the next order pipe_job.

## Example POC 2:
(I will leave installing python 3.x/PostgreSQL and making a 'test_user' up to you)
To execute the example, run the complete database script `.\db_schema\single_stored_procedure_call.sql` . Then run `start_single_call_example_processes.ps1` to start many small instances which will pick up the jobs which were created by the `pipe_job_queue`. Everything that follows should happen automatically till all four `pipe_job_queue` pipe_job's are finished and many jobs are created and processed. To run the example again, run the `truncate` operation commented at the bottom of the sql script and run the insert query right above it. This will redo the complete process.

# Some quick notes related to the second POC his behaviour:

- All timestamps are server timestamps including a timezone.
- All order 1 pipe_jobs will result in a `job_queue` job.
- When there is no pipe_job of order 1 created for a request, it is silently not picked up. Creating this pipe_job directly creates a job in the job_queue for this pipe_job
- `Finish_pipe` marks (all) parent job(s) as finished, adds finished timestamp and marks the pipe_job as finished
- (committing halfway a function is not possible) The heartbeat is ‘rolled back’ when the ‘find_job’ process fails somewhere (note that stopping due to a race condition is not a failure).
- For jobs with a job_Create_Set_Elements value of NULL or ‘’, this value will be ignored in the Job choosing process. It is considered a single Job, with 1 parent and 1 consumer.
- Priority is currently sorted so that lower numbers are processed first. The highest priority (the lowest number) of a batch determines the priority of a set of jobs (but in general those are equal because priority is determined on pipe_job level).
- If I can find a way to include the job id in the job itself when pipe_job callback is ran, I can probably support multiple equal processes in a single pipeline (e.g. A -> B -> C -> A -> D). This would increase complexity, as A -> B -> A ->… would still not be possible.
- First job will never be picked up with the ‘obtain multiple jobs’ flag of the `find_jobs` function.
- Pipe job order numbers must follow up with an increment of 1. If a gap exists between pipe_job order ID’s, the next pipe_job is not picked up. This can be fixed by adding the missing pipe_job (with the correct order) and manually firing the stored procedure: `create_entry_job(<pipe_job_id>, <pipe_id>, <priority>, row_to_json(<complete pipe_job entry>))`.
- If the `create_jobs` procedure is rolled back, it potentially leaves gaps for the primary key values in the Job_queque that are 'reserved' (if I understand correctly) due to the 'RETURNING' operation (https://www.postgresql.org/docs/9.5/dml-returning.html).
- for the `create_jobs` procedure, the job_payload's must be provided in a JSON array object (so always caught in a square ‘[]’ bracket). E.g. ‘[{"my_job": "38 None", "parent_payload": 5}]’. Then for every element in the json array, a job is created in the database. So for the payload ‘[{"my_job": "38 None", "parent_payload": 5}, {"my_job": "40 None", "parent_payload": 999}]’, 2 jobs will be created, with respectively the payloads ‘{"my_job": "38 None", "parent_payload": 5}’ and ‘{"my_job": "40 None", "parent_payload": 999}’
- Order 0 pipe line jobs will create a job_queue entry but will not, when finished, fire the next pipe_job. This is build in to make it possible to add pipeline jobs which are triggered (/added) by an external instance. An order 0 pipeline job will result in a job_queue job immediately, but will not fire the order 1 pipeline job afterwards. (It is conceptual, there is a high chance this feature will not be used. It could potentially help support running pipe_jobs which have external dependencies, where the external dependency can make it available).
- If two pipe_job order 1 jobs are finished at the same time, it could theoretically happen that both transactions find the other unfinished pipe_job.
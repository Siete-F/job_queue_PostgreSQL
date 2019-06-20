# job_queue_PostgreSQL
This repository includes 2 proof of concepts that show how to create a job_queue database with PostgreSQL.

In general, every pipeline (stored in `pipelines`) defines itself by a specific set of processes (stored in `pipeline_processes`). Processes might be reused (recycled) among pipeline definitions. If process 'A' of version 1.0.0 is used in pipe 'my_pipe' and also in 'my_sec_pipe', there is only need for one 'A' process of version '1.0.0' to run to cover all the jobs from both pipelines. Jobs for pipelines are stored in `pipe_job_queue`, which creates initial jobs in the (process interacting) job_queue. It is possible that pipes only defer by one 'process' (or module/package/service) in their pipe definition. But it is also possible that none of the processes are the same, where the pipeline is likely to perform a completely different operation.

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
- `single_stored_procedure_call`

Instead of using the PostgreSQL `NOTIFY/LISTEN` construct, we can also just create a database function (a stored procedure kind of construct which can return a value, in our case a `varchar`). This function, called from a process, returns the same kind of responses that were explained in the first POC.

This concept is expanded to include:
- job priorities
- processes that create many jobs (which will run in parallel)
- processes that get assigned 'many jobs' their outcomes and will receive a payload containing all those jobs in a json structure.
- multi order pipelines (if all order 1 `pipe_job_queue` operations are finished for a specific request, the `pipe_job_queue` order 2 jobs will be initiated by creating their first process job)
- if the last 'job_queue job'/process of a pipeline is finished, it will finish it's corresponding `pipe_job_queue` job.

So it is clearly more feature rich. Additionally it prints much smaller strings to be able to run many processes for an example run. Also no string is printed when PostgreSQL `find_job` function calls are terminated because of the 'serializable' approach which I (had to?) use (the serializable property is forced in the python script).

The term 'pipeline' refers to the flow from process A to B to C, and does not refer to a pipeline architecture, which this concept clearly does not promote. In the example data included in the `sql` scripts you will find some names for the fictional processes that are used. To help understand how the processes (and their configuration in the `pipelines` and `pipeline_processes` tables) are acting on eachother, I will explain what the individual processes are doing:
- `assigner`: Gathering metadata and preparing for the next process ->
- `wearing_compliance`: Some process that executes some job and when finished, will launch a bunch (set) of other jobs ->
- `classification`: (many jobs in parallel) A resources intensive operation which is, thanks to the previous process, properly spread over multiple processes ->
- `movemonitor`: Gathering the outcomes of the `classification` jobs and rounding up. This process fires of the `finish_pipe` stored procedure which will update the job and pipe_job 'finished' flag to `true`, which will then potentially trigger the next order pipe.

## Example POC 2:
To execute the example, run the complete database script `.\db_schema\single_stored_procedure_call.sql` (I will leave installing  python 3.x/PostgreSQL and making a 'test_user' up to you). Then run `start_single_call_example_processes.ps1` to start many small instances which will pick up the jobs which were created by the `pipe_job_queue`. Everything that follows should happen automatically till all four `pipe_job_queue` pipe_job's are finished and many jobs are created and processed. To run the example again, run the `truncate` operation commented at the bottom of the sql script and run the insert query right above it. This will redo the complete process.

# job_queue_PostgreSQL
This repository includes 2 proof of concepts that show how to create a job_queue database with PostgreSQL.

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
- processes that pick up 'many jobs' their outcomes
- multi order pipelines (if all order 1 `pipe_job_queue` operations are finished for a specific request, the `pipe_job_queue` order 2 jobs will be initiated by creating their first process job)
- if the last 'job_queue job'/process of a pipeline is finished, it will finish that `pipe_job_queue` job.

The term 'pipeline' refers to the flow from process A to B to C, it does not refer to a pipeline architecture, which this concept clearly does not promote. In the example data included in the `sql` scripts you will find some names for the fictional processes that are used. To help understand what the processes (and their configuration in the `pipelines` and `pipeline_processes` tables) are intended to do, I will explain what the individual processes are doing:
- `assigner`: Gathering metadata and preparing for the next process ->
- `wearing_compliance`: Some process that executes some job and when finished, will launch a bunch (set) of other jobs ->
- `classification`: (many jobs in parallel) A resources intensive operation which is, thanks to the previous process, properly spread over multiple processes.
- `movemonitor`: Gathering the outcomes of the `classification` jobs and rounding up. This process fires of the `finish_pipe` stored procedure which will update the job and pipe_job, which will then potentially trigger the next order pipe.

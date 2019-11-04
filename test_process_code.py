import __future__
import sys
import time
from datetime import datetime
from subprocess import Popen, PIPE, run
import json
import random
import os
import io
import re

class McRoberts_Exception(Exception):
    def __init__(self, msg):
        super().__init__(msg)

try:
    process_input = json.load(sys.stdin)
except json.JSONDecodeError as err:
    raise McRoberts_Exception('The job content could not be interpreted as message or json string.'
                              '\nThe following was received:'
                              '\n"{}"'
                              '\nWhen reading as JSON, it returned the error message:'
                              '\n{}'.format(my_job, err))

# if os.getenv("MULTIPLE_INPUTS_PROCESS", "False").lower() == 'true':
#     PROCESS_NAME = process_input[0]['job_process_name']
#     PROCESS_VERSION = process_input[0]['job_process_version']
# else:
# Not sure if there are still singular payloads. We can now conclude that there are not
PROCESS_NAME = process_input[0]['job_process_name']
PROCESS_VERSION = process_input[0]['job_process_version']
proc_uuid = os.environ["PROCESS_UUID"]
pipe_job_id = int(os.environ["PIPE_JOB_ID"])

# Handle input errors:
test_behaviour = os.getenv("BEHAVIOUR_OF_TEST_PROCESS", None)

if not test_behaviour or not test_behaviour in ['jsoncrash_stderr', 'jsoncrash_stdout', 'hardcrash',
                                                'create1job', 'create4jobs', 'pipefinish']:
    raise McRoberts_Exception('Our test process did not receive a `BEHAVIOUR_OF_TEST_PROCESS` value that it could cope'
                              ' with. Please provide this environment variable with one of the values: \'create1job\','
                              ' \'create4jobs\', \'pipefinish\'. If it is desired to mimic a crash, use'
                              ' \'jsoncrash_stderr\' for a controlled crash action (writes an error to the stderr'
                              ' in json format), \'jsoncrash_stdout\' for a json formatted error to stdout, or'
                              ' \'hardcrash\' for an uncaught error (caused by `sum(\'a\', \'b\')`).'
                              ' Current value was {}'.format(test_behaviour))

elif test_behaviour == 'jsoncrash_stderr':
    print(json.dumps({"level": "ERROR", "timestamp": datetime.now().isoformat(),
                      "message": '(stderr) Our test process is requested to return a json formatted crash over the stderr.'
                      ' It runs `exit(-1)` after that.', "pipe_job_id": pipe_job_id, "process_name": PROCESS_NAME,
                      "process_version": PROCESS_VERSION, "uuid": proc_uuid}), file=sys.stderr)
    exit(-1)
elif test_behaviour == 'jsoncrash_stdout':
    print(json.dumps({"level": "ERROR", "timestamp": datetime.now().isoformat(),
                      "message": '(stdout) Our test process is requested to return a json formatted crash over the stdout.'
                      ' It runs `exit(-1)` after that.', "pipe_job_id": pipe_job_id, "process_name": PROCESS_NAME,
                      "process_version": PROCESS_VERSION, "uuid": proc_uuid}))
    exit(-1)
elif test_behaviour == 'hardcrash':
    # Force a raw crash
    sum('a', 'b')

pretty_job_pickup_str = ','.join([str(o['job_id']) + ' ' + str(o['job_creater_process_name']) for o in process_input])
print(json.dumps({"level": "INFO", "timestamp": datetime.now().isoformat(),
                  "message": 'received {} payloads from jobs {}.'.format(len(process_input), pretty_job_pickup_str),
                  "n_payloads": len(process_input), "pipe_job_id": pipe_job_id, "process_name": PROCESS_NAME,
                  "process_version": PROCESS_VERSION, "uuid": proc_uuid}))

proc_start = datetime.now()
# On success, sleep random time up to 10 sec (mimicking real processing time)
# Mimic quick assigner process and slower classification process.
time.sleep(max(0, random.random() * 5 + 2 * (PROCESS_NAME == 'classification') - 2 * (PROCESS_NAME == 'assigner')))
proc_end = datetime.now()

print(json.dumps({"level": "INFO", "timestamp": datetime.now().isoformat(),
                  "message": 'Process finished running.',
                  "start_timestamp": proc_start.isoformat(), "end_timestamp": proc_end.isoformat(),
                  "time_taken": (proc_end-proc_start).total_seconds(), "pipe_job_id": pipe_job_id,
                  "process_name": PROCESS_NAME, "process_version": PROCESS_VERSION, "uuid": proc_uuid}))

payload_to_return = '{"my_job": "%s", "parent_payload": %s}' % (pretty_job_pickup_str,
                                                                json.dumps([x['job_payload'] for x in process_input]))

def perform_stdin_operation(cmd_str, stdin_payload=None):
    p = Popen(cmd_str.split(' '), stdin=PIPE, stdout=PIPE, stderr=PIPE)
    stdout, stderr = p.communicate(input=bytes(stdin_payload + '\n', encoding='utf-8'))
    if stdout:
        # The stdout appears to have a double newline at the end (at least with Rscript calls).
        print(re.sub(r'\n\n$', '\n', stdout.decode()))
    if stderr:
        raise McRoberts_Exception(stderr.decode())

def perform_operation(cmd_str):
    p = run(cmd_str.split(' '), universal_newlines=True, stdout=PIPE, stderr=PIPE)
    if p.stdout:
        # The stdout appears to have a double newline at the end (at least with Rscript calls).
        print(re.sub(r'\n\n$', '\n', p.stdout))
    if p.stderr:
        raise McRoberts_Exception(p.stderr)

### Roundup ###
if test_behaviour == 'create1job':
    # For any other process:
    perform_stdin_operation("python /job_queue/create_job.py %s" % ','.join([str(x['job_id']) for x in process_input]),
                      '[%s]' % payload_to_return)
elif test_behaviour == 'create4jobs':
    # After 1 is finished processing, fire 1 to 6 jobs:
    n_proc = round(random.random() * 5 + 1)
    perform_stdin_operation("python /job_queue/create_job.py %s" % ','.join([str(x['job_id']) for x in process_input]),
                      '[' + ','.join(['{}'] * n_proc).format(*[payload_to_return] * n_proc) + ']')
elif test_behaviour == 'pipefinish':
    # last process should fire pipe finish.
    perform_operation("python /job_queue/finish_pipe_job.py %s %1.0f" %
                      (','.join([str(x['job_id']) for x in process_input]),  # job id's
                       process_input[0]['pipe_job_id']))  # pipe job id

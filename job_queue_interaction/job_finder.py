from datetime import datetime
from subprocess import Popen, PIPE
from mcr_connections import make_job_queue_connection
import os
import sys
import traceback
import __future__  # for printing to stderr
import platform
import time

import json
import psycopg2
#import psycopg2.extensions
from jsonschema import validate

PROCESS_NAME            = os.getenv("PROCESS_NAME", 'nameless_process')
PROCESS_VERSION         = os.getenv("PROCESS_VERSION", '99.99.99')
MULTIPLE_INPUTS_PROCESS = os.getenv("MULTIPLE_INPUTS_PROCESS", 'False').lower() == 'true'
PROCESS_CMD_CALL        = os.getenv("PROCESS_CMD_CALL", 'python python -c "print(\'Hallo world\')"')
JSON_SCHEMA_LOCATION    = os.getenv("JSON_SCHEMA_LOCATION")
unique_uuid_code        = os.getenv('HOSTNAME', os.getenv('COMPUTERNAME', platform.node())).split('.')[0]
server_name             = os.getenv("DOCKER_HOST_NAME", 'Not provided at microservice startup')

# Load JSON schema for input validation.
if JSON_SCHEMA_LOCATION:
    with open(JSON_SCHEMA_LOCATION, 'r') as fid:
        input_json_schema = json.load(fid)

    print(json.dumps({"level": "INFO", "timestamp": str(datetime.now()),
                      "message": 'json_input_schema validation file has been loaded for later input validation.',
                      "process_name": PROCESS_NAME, "process_version": PROCESS_VERSION, "uuid": unique_uuid_code}))
else:
    print(json.dumps({"level": "WARN", "timestamp": str(datetime.now()),
                      "message": 'NO json_input_schema is loaded. this because no `JSON_SCHEMA_LOCATION` '
                                 'env var could be found. No input quality checks will be performed!',
                      "process_name": PROCESS_NAME, "process_version": PROCESS_VERSION, "uuid": unique_uuid_code}))

if unique_uuid_code == 'docker-desktop':
    unique_uuid_code = uuid.uuid4().hex[0:12]





def obtain_job(multi_job_process):
    conn = make_job_queue_connection()
    curs = None
    try:
        curs = conn.cursor()
        curs.execute("SELECT find_job(%s, %s, %s, %s, %s);",
                     (unique_uuid_code, server_name, PROCESS_NAME, PROCESS_VERSION, multi_job_process))
        conn.commit()
        value = curs.fetchone()[0]
    except KeyError as e:
        print('An error occurred when fetching the job request. Containing:\n{}'.format(e), file=sys.stderr)
    except psycopg2.OperationalError as e:
        print('A "psycopg2.OperationalError" is fired. The following error msg is associated:\n{}'.format(e),
              file=sys.stderr)
        # return 'retry'
    except Exception as e:
        print('An error occurred during a job request.', file=sys.stderr)
        print(e, file=sys.stderr)
        # This is not mandatory error handling, but provides us
        # with the construct to build our own proper error handling.
        if curs is not None:
            conn.rollback()
    finally:
        conn.close()
        if (curs):
            curs.close()

    return value


def listen():
    wait_start = datetime.now()
    print(json.dumps({"level": "INFO", "timestamp": str(datetime.now()), "message": "Process STARTUP successful!",
                      "process_name": PROCESS_NAME, "process_version": PROCESS_VERSION, "uuid": unique_uuid_code}))

    while 1:
        try:
            ### find job ###
            # For 'merging_results' expect multiple jobs (converging activity, as described below)
            my_job = obtain_job(multi_job_process=MULTIPLE_INPUTS_PROCESS)

            if my_job:
                # When no job is found, wait 5 seconds and try again.
                if my_job.lower() == 'retry, i lost the job race':
                    print(json.dumps(
                        {"level": "INFO", "timestamp": str(datetime.now()), "message": 'Retrying, lost job race.',
                         "process_name": PROCESS_NAME, "process_version": PROCESS_VERSION, "uuid": unique_uuid_code}))
                    continue

                if my_job.lower() == 'no job found':
                    check_freq = 5
                    if (datetime.now() - wait_start).total_seconds() > 5 * 60:  # Notify us every 5 minutes.
                        print(json.dumps({"level": "INFO", "timestamp": str(datetime.now()),
                                          "message": 'No job found. Checking every {} seconds, logging with minimum of 5 min in between.'.format(
                                              check_freq),
                                          "process_name": PROCESS_NAME, "process_version": PROCESS_VERSION,
                                          "uuid": unique_uuid_code}))
                        wait_start = datetime.now()
                    time.sleep(check_freq)
                    continue

                # If a 'kill' command was send, stop processing.
                if my_job.lower() == 'kill':
                    print(json.dumps({"level": "WARN", "timestamp": str(datetime.now()),
                                      "message": 'Process has been terminated by a kill request.',
                                      "process_name": PROCESS_NAME, "process_version": PROCESS_VERSION,
                                      "uuid": unique_uuid_code}))
                    return

                ### Processing ###
                # If a job is found (i.e. no 'no job found', 'retry, i lost the job race' or 'kill' was returned)
                # run subprocess that is instructed by env var:
                print(json.dumps(
                    {"level": "INFO", "timestamp": str(datetime.now()), "message": 'Job found!', "process_name":
                        PROCESS_NAME, "process_version": PROCESS_VERSION, "uuid": unique_uuid_code}))

                # If json schema validation is available, validate the input:
                if JSON_SCHEMA_LOCATION:
                    print(json.dumps({"level": "DEBUG", "timestamp": str(datetime.now()), "message":
                        'starting JSON schema validation.', "process_name": PROCESS_NAME,
                                      "process_version": PROCESS_VERSION, "uuid": unique_uuid_code}))

                    # Throws error on reading failure.
                    # The payload should already be valid json because it has been inserted into a JSON database field.
                    # Invalid json cannot be inserted in the first place with e.g. `create_job` or another procedure.
                    payload = json.loads(my_job)

                    # Throws error on failure
                    validate(payload, schema=input_json_schema)
                    
                    if type(payload) is list:
                        job_id = [x['job_id'] for x in payload]
                    elif type(payload) is dict:
                        job_id = [payload['job_id']]
                    else:
                        job_id = 'No list or dict of jobs found in the payload!!'
                        
                    print(json.dumps({"level": "INFO", "timestamp": str(datetime.now()),
                                      "message": 'json_input_schema validation successful.', "job_id": job_id, 
                                      "process_name": PROCESS_NAME, "process_version": PROCESS_VERSION, "uuid": unique_uuid_code,
                                      "job_payload_fields": [str(x) for x in payload[0]['job_payload'].keys()]}))

                print(json.dumps({"level": "INFO", "timestamp": str(datetime.now()), "message":
                    "Launching child process with the provided call: '" + PROCESS_CMD_CALL + "'.", "process_name":
                                      PROCESS_NAME, "process_version": PROCESS_VERSION, "uuid": unique_uuid_code}))

                # reading from stdin expects newline at end of file.
                p = Popen(PROCESS_CMD_CALL.split(' '), stdin=PIPE, stdout=PIPE, stderr=PIPE)
                stdout, stderr = p.communicate(input=bytes(my_job + '\n', encoding='utf-8'))
                
                if stdout:
                    print(stdout.decode())
                else:
                    print(json.dumps({"level": "DEBUG", "timestamp": str(datetime.now()), "message":
                        "No stdout was returned by the process. It is advised to create at least a single log within the process itself.", "process_name": PROCESS_NAME, 
                        "process_version": PROCESS_VERSION, "uuid": unique_uuid_code}))

                if stderr:
                    raise McRoberts_Exception(stderr.decode())
                else:
                    print(json.dumps({"level": "DEBUG", "timestamp": str(datetime.now()), "message":
                        "No stderr was returned by the process.", "process_name": PROCESS_NAME, 
                        "process_version": PROCESS_VERSION, "uuid": unique_uuid_code}))

            if my_job is None:
                raise McRoberts_Exception('An obtain_job call was initiated, but no value was returned for process {} '
                                          'with version {}!'.format(PROCESS_NAME, PROCESS_VERSION))

        except McRoberts_Exception as err:
            exc_type, exc_value, exc_traceback = sys.exc_info()
            print(json.dumps({"level": "ERROR", "timestamp": str(datetime.now()),
                              "message": 'A McRoberts Exception occurred!! McR ERROR: "{}". This process will continue to search for jobs again.'.format(
                                  str(err)), "error_msg": str(err),
                              "error_traceback": repr(traceback.format_exception(exc_type, exc_value, exc_traceback)),
                              "process_name": PROCESS_NAME, "process_version": PROCESS_VERSION,
                              "uuid": unique_uuid_code}), file=sys.stderr)
            time.sleep(5)

        except Exception as err:
            exc_type, exc_value, exc_traceback = sys.exc_info()
            print(json.dumps({"level": "CRIT", "timestamp": str(datetime.now()),
                              "message": 'The following error occured: "{}". This process will continue to search for jobs again.'.format(
                                  str(err)), "error_msg": str(err),
                              "error_traceback": repr(traceback.format_exception(exc_type, exc_value, exc_traceback)),
                              "process_name": PROCESS_NAME, "process_version": PROCESS_VERSION,
                              "uuid": unique_uuid_code}), file=sys.stderr)
            time.sleep(5)


class McRoberts_Exception(Exception):
    def __init__(self, msg):
        super().__init__(msg)


if __name__ == '__main__':
    listen()
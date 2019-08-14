import sys
import time
import datetime
import json
import uuid
import atexit
import random

import psycopg2
import psycopg2.extensions

PROCESS_NAME     = 'first_process'
PROCESS_VERSION  = '1.9.2'
# If this script is called from the commandline, it expects 2 input arguments
if sys.stdin.isatty():
    PROCESS_NAME    = sys.argv[1]
    PROCESS_VERSION = sys.argv[2]

unique_uuid_code = uuid.uuid4().hex[0:12]
server_name      = 'MyServer'

def make_connection():
    return (psycopg2.connect("dbname=single_procedure_job_queue user=test_user password='test_user'"))

def obtain_job(multi_job_process):
    conn = make_connection()
    curs = None
    try:
        curs = conn.cursor()
        query = "SELECT find_job('{}', '{}', '{}', '{}', {});".format(unique_uuid_code, server_name, PROCESS_NAME, PROCESS_VERSION, multi_job_process)
        curs.execute(query)
        conn.commit()
        value = curs.fetchone()[0]
        return value
    except KeyError as e:
        print('An error occurred when fetching the job request. Containing:\n{}'.format(e))
    except psycopg2.OperationalError as e:
        print('A "psycopg2.OperationalError" is fired. The following error msg is associated:\n{}'.format(e))
        # return 'retry'
    except Exception as e:
        print('An error occurred during a job request.')
        print(e)
        # This is not mandatory error handling, but provides us
        # with the construct to build our own proper error handling.
        if curs is not None:
            conn.rollback()
    finally:
        if (conn):
            curs.close()
            conn.close()

def create_jobs(my_job_id, next_job_payload):
    conn = make_connection()
    curs = None
    try:
        curs = conn.cursor()
        query = "CALL create_jobs(ARRAY[{}], '{}');".format(','.join(str(x) for x in my_job_id), next_job_payload)
        curs.execute(query)
        conn.commit()
    except KeyError as e:
        print('The fired job_request did not return a value. An error occurred when fetching the job request. Error:\n{}'.format(e))
    except psycopg2.OperationalError as e:
        print('A "psycopg2.OperationalError" is fired on CREATE_JOBS operation! This is unexpected... The following error msg is associated:')
        print(e)
    except Exception as e:
        print('An error occurred during a job request.')
        print(e)
    finally:
        if (conn):
            curs.close()
            conn.close()

def mark_pipe_job_finished(job_ids, pipe_job_id):
    conn = make_connection()
    curs = None
    try:
        curs = conn.cursor()
        query = "CALL finish_pipe(ARRAY[{}], '{}');".format(','.join(str(x) for x in job_ids), pipe_job_id)
        curs.execute(query)
        conn.commit()
    except psycopg2.OperationalError as e:
        print('A "psycopg2.OperationalError" is fired on FINISH_PIPE operation! This is unexpected... The following error msg is associated:')
        print(e)
    except Exception as e:
        print('An error occurred during a job request.')
        print(e)
    finally:
        if (conn):
            curs.close()
            conn.close()

class McRoberts_Exception(Exception):
    def __init__(self, msg):
        super().__init__(msg)

def listen():

    while 1:
        try:
            ### find job ###
            # For 'merging_results' expect multiple jobs (converging activity, as described below)
            my_job = obtain_job(PROCESS_NAME in ['merging_results'])

            # In my imagination, the processes do something like this:
            # (A much more detailed description can be found in README.md)

            # assigner,    gathers som metadata              ||||||
            #              and creates classif jobs         ///  \\\
            # classification, classifies stuff             |||    |||
            # merging_results,  gathers the batch jobs      \\\  ///
            # uploader,  gets payload                        ||||||
            #              and upload on final place          {*,*}
            #
            # last task will receive the complete payload chain in this test script.

            if my_job:
                # When no job is found, wait 5 seconds and try again.
                if my_job.lower() == 'retry, i lost the job race':
                    print('Retrying, lost job race.')
                    continue

                if my_job.lower() == 'no job found':
                    print('No jobs, {} {} {}.'.format(PROCESS_NAME, PROCESS_VERSION, unique_uuid_code))
                    time.sleep(5)
                    continue

                # If a 'kill' command was send, stop processing.
                if my_job.lower() == 'kill':
                    print('The process has been terminated by a "KILL" notification.')
                    return

                ### Processing ###
                # If a job is found (i.e. no 'no job found', 'retry, i lost the job race' or 'kill' was returned)
                # Read it as json string
                try:
                    process_input = json.loads(my_job)
                except json.JSONDecodeError as err:
                    raise McRoberts_Exception('The job content could not be interpreted as message or json string.'
                             '\nThe following was received:\n"{}"\nWhen reading as JSON, it returned the error message:\n{}'.format(my_job, err))

                pretty_job_pickup_str = ','.join([str(o['job_id']) + ' ' + str(o['job_creater_process_name']) for o in process_input])
                print('received {} payloads from jobs {}.'.format(len(process_input), pretty_job_pickup_str))

                # On success, sleep random time up to 10 sec (mimicking real processing time)
                time.sleep(random.random()*5)

                ### Roundup ###
                payload = '{"my_job": "%s", "parent_payload": %s}' % (pretty_job_pickup_str, json.dumps([x['job_payload'] for x in process_input]))
                if PROCESS_NAME == 'assigner':
                    # After 1 is finished processing, fire 4 jobs:
                    create_jobs([x['job_id'] for x in process_input], '[{}, {}, {}, {}]'.format(payload, payload, payload, payload))

                elif PROCESS_NAME in ['uploader', 'third_process', 'wc_upload', 'creating_report']:
                    # last process should fire pipe finish.
                    mark_pipe_job_finished([x['job_id'] for x in process_input], process_input[0]['pipe_job_id'])

                else:
                    # For any other process:
                    create_jobs([x['job_id'] for x in process_input], '[%s]' % payload)

            if my_job is None:
                raise McRoberts_Exception('An obtain_job call was initiated, but no value was returned for process {} '
                                          'with version {}!'.format(PROCESS_NAME, PROCESS_VERSION))
                time.sleep(1)

        except McRoberts_Exception as err:
            print('\nA McRoberts Exception occurred!!\n\nMcR ERROR:\n{}\n\n'
                  'This process will begin with `find_job` again.'.format(err))
            time.sleep(5)

        except Exception as err:
            print('\nCritical error occurred!!\n\nERROR:\n{}\n'
                  'This process will begin with `find_job` again.\n'.format(err))
            time.sleep(5)


if __name__ == '__main__':
    listen()

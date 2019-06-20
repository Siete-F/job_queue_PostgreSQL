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
        curs.execute("START TRANSACTION ISOLATION LEVEL SERIALIZABLE;")
        query = "SELECT find_job('{}', '{}', '{}', '{}', {});".format(
            unique_uuid_code, server_name, PROCESS_NAME, PROCESS_VERSION, multi_job_process)

        curs.execute(query)
        conn.commit()
        value = curs.fetchone()[0]
        return value
    except KeyError as e:
        print('An error occurred when fetching the job request. Containing:\n{}'.format(e))
    except psycopg2.OperationalError as e:
        # print('A "psycopg2.OperationalError" is fired. This is okey since it is a side effect of preventing the race condition.')
              # 'processes to pick up the same job. The following error msg is associated:\n{}'.format(e))
        return 'retry'
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

def create_job(my_job_id, job_set_size, next_job_payload):
    conn = make_connection()
    curs = None
    try:
        curs = conn.cursor()
        query = "CALL create_job('{}', '{}', '{}');".format(my_job_id, job_set_size, next_job_payload)
        curs.execute(query)
        conn.commit()

    except KeyError as e:
        print('The fired job_request did not return a value. An error occurred when fetching the job request. Error:\n{}'.format(e))
    except psycopg2.OperationalError as e:
        print('A "psycopg2.OperationalError" is fired on CREATE_JOB operation! This is unexpected... The following error msg is associated:')
        print(e)
    except Exception as e:
        print('An error occurred during a job request.')
        print(e)
    finally:
        if (conn):
            curs.close()
            conn.close()

def mark_pipe_job_finished(pipe_job_id, job_id):
    conn = make_connection()
    curs = None
    try:
        curs = conn.cursor()
        query = "CALL finish_pipe('{}', '{}');".format(pipe_job_id, job_id)
        curs.execute(query)
        conn.commit()
    except psycopg2.OperationalError as e:
        print('A "psycopg2.OperationalError" is fired on CREATE_JOB operation! This is unexpected... The following error msg is associated:')
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

    # conn = psycopg2.connect("dbname=single_procedure_job_queue user=test_user password='test_user'")

    while 1:
        try:
            ### find job ###
            my_job = obtain_job(PROCESS_NAME in ['movemonitor'])  # if inside check is true, multiple jobs are expected (converging)

            # assigner,            starts many heavy tasks   ||||||
            # wearing_compliance,  performs WC               ||||||
            #              and creates classif jobs         ///  \\\
            # classification, classifies stuff             |||    |||
            # movemonitor,  gathers the batch jobs          \\\  ///
            #              and upload on final place         {*,*}

            if my_job:
                # When no job is found, wait 5 seconds and try again.
                if my_job == 'retry':
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
                # If, apparently, a job is found (since no 'no job found' or 'kill' was returned, but something else...)
                # Read it as json string
                try:
                    process_input = json.loads(my_job)
                except json.JSONDecodeError as err:
                    raise McRoberts_Exception('The job content could not be interpreted as json string.'
                             '\nThe following was received:\n{}\nWith error message:\n{}'.format(my_job, err))

                print('received {} payloads from jobs {}.'.format(len(process_input), ','.join([str(o['job_id']) + ' ' + o['job_create_process_name'] for o in process_input])))
                time.sleep(random.random()*10)

                ### Roundup ###
                if PROCESS_NAME == 'wearing_compliance':
                    # After 1 is finished processing:
                    create_job(process_input[0]['job_id'], 4, '{"new_payload": "first payload!!"}')
                    create_job(process_input[0]['job_id'], 4, '{"new_payload": "second payload!!"}')
                    create_job(process_input[0]['job_id'], 4, '{"new_payload": "third payload!!"}')
                    create_job(process_input[0]['job_id'], 4, '{"new_payload": "fourth payload!!"}')
                elif PROCESS_NAME in ['movemonitor', 'third_process', 'wc_upload', 'creating_report']:
                    # last process should fire pipe finish.
                    mark_pipe_job_finished(process_input[0]['pipe_job_id'], process_input[0]['job_id'])
                else:
                    # For any other process:
                    create_job(process_input[0]['job_id'], 1, '{"my_job_id": %1.0f}' % process_input[0]['job_id'])

            if my_job is None:
                raise McRoberts_Exception('An obtain_job call was initiated, but no value was returned for process {} '
                                          'with version {}!'.format(PROCESS_NAME, PROCESS_VERSION))
                time.sleep(1)

        except McRoberts_Exception as err:
            print('\nA McRoberts Exception occurred!!\n\nMcR ERROR:\n{}\n\n'
                  'This process will begin with the heartbeat again.'.format(err))
            time.sleep(5)

        except Exception as err:
            print('\nCritical error occurred!!\n\nERROR:\n{}\n'
                  'This process will begin with the heartbeat again.\n'.format(err))
            time.sleep(5)


if __name__ == '__main__':
    listen()
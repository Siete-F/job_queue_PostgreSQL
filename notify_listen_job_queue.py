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
PROCESS_VERSION  = '1.0.0'
# If this script is called from the commandline, it expects 2 input arguments
if sys.stdin.isatty():
    PROCESS_NAME    = sys.argv[1]
    PROCESS_VERSION = sys.argv[2]

unique_uuid_code = uuid.uuid4().hex[0:12]
server_name      = 'MyServer'
print('Running process uuid: {}, named "{}" of version "{}".'.
      format(unique_uuid_code, PROCESS_NAME, PROCESS_VERSION))

def make_connection():
    return (psycopg2.connect("dbname=normalized_example user=test_user password='test_user'"))

def send_heartbeat(conn):
    curs2 = None
    try:
        curs2 = conn.cursor()
        # The following statement makes the stored procedure and the trigger that it fires run in serializable mode.
        # This completely solves the race condition issue.
        curs2.execute("START TRANSACTION ISOLATION LEVEL SERIALIZABLE;")
        curs2.execute("CALL send_heartbeat('{}', '{}', '{}', '{}');".format(
            unique_uuid_code, server_name, PROCESS_NAME, PROCESS_VERSION))
        conn.commit()
    except psycopg2.OperationalError as e:
        print('A "psycopg2.OperationalError" is fired, and the following error is returned:\n{}'.format(e))
        return 'retry'

    except Exception as e:
        print('An error occurred during a heartbeat.')
        print(e)
        # This is not mandatory error handling, but provides us
        # with the construct to build our own proper error handling.
        if curs2 is not None:
            conn.rollback()
    finally:
        # I don't want to close the connection.
        pass
        #if cursor is not None:
        #    curs2.close()

class McRoberts_Exception(Exception):
    def __init__(self, msg):
        super().__init__(msg)

def listen():
    conn = make_connection()

    atexit.register(conn.close)

    # conn = psycopg2.connect("dbname=normalized_example user=siete password='Quga2092*'")

    channel = "channel_{}".format(unique_uuid_code.lower())

    curs = conn.cursor()
    curs.execute('LISTEN "{}";'.format(channel))

    print("Waiting for notifications on channel '{}'".format(channel))

    while 1:
        try:
            # Clear any notifications.
            conn.notifies.clear()

            # Fire heartbeat (an insert or timestamp update of the Process_heartbeats table)
            send_heartbeat(conn)

            # Current time
            startUnix = time.time()
            notify = None
            process_input = None
            # look for notifications for less then 3 seconds.
            while (time.time() - startUnix) < 3:
                conn.poll()

                if conn.notifies:
                    if len(conn.notifies) > 1:
                        print(conn.notifies)
                        raise McRoberts_Exception('Multiple notifications ({}) are recieved on channel "{}" and we dont know how to deal with them!!\nContent:\n{}'.format(len(conn.notifies), channel, conn.notifies))
                    notify = conn.notifies.pop()

                    # When no job is found, wait 5 seconds and try again.
                    if notify.payload == 'No job found':
                        # When the heartbeat and associated trigger was terminated due to a simultanious write,
                        print('No jobs were found, sending next heartbeat in 1 sec on channel "{}".'.format(notify.channel))
                        time.sleep(1)
                        break

                    # If a 'kill' command was send, stop processing.
                    if notify.payload.lower() == 'kill':
                        print('The process has been terminated by a "KILL" notification.')
                        return

                    # If, apparently, a job is found (since no 'no job found' or 'kill' was returned, but something else...)
                    # Read it as json string
                    try:
                        process_input = json.loads(notify.payload)
                    except json.JSONDecodeError as err:
                        raise McRoberts_Exception('The notified message on channel "{}" could not be interpreted as json string.'
                              '\nThe following was received:\n{}\nWith error message:\n{}'.format(notify.channel, notify, err))

                    print('SUCCESS!!\nWe received the following payload and could convert it to a json structure.\n\n{}'.format(process_input))

                    time.sleep(random.random())
                    #1, 1,    '{"your task": "Now do a shitload of work"}',     'conthash',     'first_process',  '1.0.0'
                    curs.execute("CALL create_job('{}', '{}', '{}', '{}', '{}', '{}');".format(
                        1, 1, '{"your task": "Now do a shitload of work"}', unique_uuid_code, PROCESS_NAME, PROCESS_VERSION))

                    conn.commit()

            if notify is None:
                raise McRoberts_Exception('A heartbeat was sent by process {} with version {} '
                       'and was listening on channel {}, but no notification was received!'.format(
                        PROCESS_NAME, PROCESS_VERSION, channel))

        except McRoberts_Exception as err:
            print('\nA McRoberts Exception occurred!!\n\nMcR ERROR:\n{}\n\nThis process will begin with the heartbeat again.'.format(err))
            time.sleep(5)

        except Exception as err:
            print('\nCritical error occurred!!\n\nERROR:\n{}\n'
                  'This process will begin with the heartbeat again.\n'.format(err))
            time.sleep(5)


if __name__ == '__main__':
    listen()
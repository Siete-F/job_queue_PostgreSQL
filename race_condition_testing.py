import sys
import time
# import datetime
# import json
# import uuid
# import atexit
# import random

import psycopg2
import psycopg2.extensions

PROCESS_NAME     = 'TESTING'
# If this script is called from the commandline, it expects 2 input arguments
if sys.stdin.isatty():
    PROCESS_NAME = sys.argv[1]

def make_connection():
    return (psycopg2.connect("dbname=simultanious_job_pickup_test user=test_user password='test_user'"))

def pickup_job():
    conn = make_connection()
    curs = None
    try:
        curs = conn.cursor()
        # curs.execute("START TRANSACTION ISOLATION LEVEL SERIALIZABLE;")
        query = "SELECT sample_id FROM job_queue_pickup_test WHERE process_name IS NULL LIMIT 5 FOR UPDATE;"
        curs.execute(query)
        conn.commit()
        IDs = curs.fetchall()

        if IDs:
            id_str = 'ARRAY[' + ','.join([str(x[0]) for x in IDs]) + ']'
            query = "INSERT INTO job_queue_pickup_race (sample_ids, process_name) VALUES ({}, '{}');".format(
                id_str, PROCESS_NAME)
            curs.execute(query)
            conn.commit()

            query = "UPDATE job_queue_pickup_test SET process_name = '{}' WHERE sample_id IN ({})".format(PROCESS_NAME, ','.join([str(x[0]) for x in IDs]))
            print(query)
            curs.execute(query)
            conn.commit()

            query = "UPDATE job_queue_pickup_count SET count = count + {} WHERE process_name = '{}'".format(len(IDs), PROCESS_NAME)
            curs.execute(query)
            conn.commit()

    except KeyError as e:
        print('An error occurred when fetching the job request. Containing:\n{}'.format(e))
    except psycopg2.IntegrityError as e:
        print('UniqueViolation occurred. This is desired.')
        print(e)
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


class McRoberts_Exception(Exception):
    def __init__(self, msg):
        super().__init__(msg)

def goforit():

    while 1:
        try:
            ### pickup job ###
            pickup_job()
            # time.sleep(0.1)

        except McRoberts_Exception as err:
            print('\nA McRoberts Exception occurred!!\n\nMcR ERROR:\n{}\n\n'
                  'This process will begin with the heartbeat again.'.format(err))
            time.sleep(5)

        except Exception as err:
            print('\nCritical error occurred!!\n\nERROR:\n{}\n'
                  'This process will begin with the heartbeat again.\n'.format(err))
            time.sleep(5)


if __name__ == '__main__':
    goforit()


################################################
# query = "SELECT sample_id FROM job_queue_pickup_test WHERE process_name IS NULL LIMIT 1;"
# curs.execute(query)
# conn.commit()
# ID = curs.fetchone()[0]
#
# if ID:
#     query = "UPDATE job_queue_pickup_test SET process_name = '{}' WHERE sample_id = {} AND ".format(PROCESS_NAME, ID)
#     curs.execute(query)
#     conn.commit()
#
#     query = "UPDATE job_queue_pickup_count SET count = count + 1 WHERE process_name = '{}'".format(PROCESS_NAME)
#     curs.execute(query)
#     conn.commit()


# process_name|real_count|comsumed_count|
# ------------|----------|--------------|
# process_1   |       498|           519|
# process_2   |       517|           536|
# process_3   |       485|           515|
# process_4   |       500|           530|
################################################

################################################
# query = "SELECT sample_id FROM job_queue_pickup_test WHERE process_name IS NULL LIMIT 1;"
# curs.execute(query)
# conn.commit()
# ID = curs.fetchone()[0]
#
# if ID:
#     query = "UPDATE job_queue_pickup_test SET process_name = '{}' WHERE sample_id = {} AND process_name is null;".format(  <<<<<<<<<<<<<<<<<< is null is added, but obviously does not change anything. It makes that the first one is left, instead of overwritten.
#         PROCESS_NAME, ID)
#     curs.execute(query)
#     conn.commit()
#
#     query = "UPDATE job_queue_pickup_count SET count = count + 1 WHERE process_name = '{}'".format(PROCESS_NAME)
#     curs.execute(query)
#     conn.commit()

# process_name|real_count|comsumed_count|
# ------------|----------|--------------|
# process_1   |       487|           523|
# process_2   |       499|           542|
# process_3   |       511|           554|
# process_4   |       503|           544|
################################################

################################################
# query = "SELECT sample_id FROM job_queue_pickup_test WHERE process_name IS NULL LIMIT 1;"
# curs.execute(query)
# conn.commit()
# ID = curs.fetchone()
#
# if ID is not None:
#     query = "UPDATE job_queue_pickup_test SET process_name = '{}' WHERE sample_id = {} AND process_name is null;".format(
#         PROCESS_NAME, ID[0])
#     curs.execute(query)
#     conn.commit()
#
#     query = "SELECT sample_id FROM job_queue_pickup_test WHERE sample_id = {} AND process_name = '{}';".format(ID[0],
#                                                                                                                PROCESS_NAME)
#     curs.execute(query)
#     conn.commit()
#     isMINE = curs.fetchone()
#
#     if isMINE is not None:
#         query = "UPDATE job_queue_pickup_count SET count = count + 1 WHERE process_name = '{}'".format(PROCESS_NAME)
#         curs.execute(query)
#         conn.commit()

# process_name|real_count|comsumed_count|
# ------------|----------|--------------|
# process_1   |       521|           521|
# process_2   |       498|           498|                          WORKS!!!!!!!!!
# process_3   |       494|           494|
# process_4   |       487|           487|
################################################

################################################
# query = "SELECT sample_id FROM job_queue_pickup_test WHERE process_name IS NULL LIMIT 2 FOR UPDATE;"
# curs.execute(query)
# conn.commit()
# IDs = curs.fetchall()
#
# if IDs:
#     id_str = '[' + ','.join([str(x[0]) for x in IDs]) + ']'
#     query = "INSERT INTO job_queue_pickup_race (sample_ids, process_name) VALUES ('{}', '{}');".format(
#         id_str, PROCESS_NAME)
#     curs.execute(query)
#     conn.commit()
#
#     query = "UPDATE job_queue_pickup_test SET process_name = '{}' WHERE sample_id IN ({})".format(PROCESS_NAME,
#                                                                                                   ','.join(
#                                                                                                       [str(x[0]) for x
#                                                                                                        in IDs]))
#     print(query)
#     curs.execute(query)
#     conn.commit()
#
#     query = "UPDATE job_queue_pickup_count SET count = count + {} WHERE process_name = '{}'".format(len(IDs),
#                                                                                                     PROCESS_NAME)
#     curs.execute(query)
#     conn.commit()

# process_name|real_count|comsumed_count|
# ------------|----------|--------------|
# process_1   |       522|           522|
# process_2   |       514|           514|
# process_3   |       470|           470|
# process_4   |       494|           494|
################################################

################################################

################################################

################################################

################################################

################################################

################################################


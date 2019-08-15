import uuid
import atexit
import random

import psycopg2
import psycopg2.extensions

def make_connection():
    return (psycopg2.connect("dbname=measurements user=measurement_user password='test_user'"))

def copy_to_db(filename):
    conn = make_connection()
    curs = None
    try:
        curs = conn.cursor()
        query = "COPY dummy ({}) FROM '{}';".format('Timestamp, SignalMedioLateral, SignalCaudalCranial, SignalDorsalVentral', filename)
        curs.execute(query)
        conn.commit()
    except psycopg2.OperationalError as e:
        print('A "psycopg2.OperationalError" is fired on CREATE_JOB operation! This is unexpected... The following error msg is associated:')
        print(e)
    except Exception as e:
        print('An error occurred during a job request.')
        print(e)
    finally:
        if (curs):
            curs.close()
            conn.close()

if __name__ == '__main__':
    copy_to_db('C:\\analysis_data\\database_write_test_data\\converted.csv')
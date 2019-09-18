import __future__
#import psycopg2.extensions
import sys
from mcr_connections import make_job_queue_connection

def create_jobs(my_job_id, next_job_payload):
    conn = make_job_queue_connection()
    curs = None
    try:
        curs = conn.cursor()
        query = "CALL create_jobs(ARRAY[{}], '{}');".format(','.join(str(x) for x in my_job_id), next_job_payload)
        curs.execute(query)
        conn.commit()
    except KeyError as e:
        print('The fired job_request did not return a value. An error occurred when fetching the job request. Error:\n{}'.format(e), file=sys.stderr)
    except psycopg2.OperationalError as e:
        print('A "psycopg2.OperationalError" is fired on CREATE_JOBS operation! This is unexpected... The following error msg is associated:', file=sys.stderr)
        print(e, file=sys.stderr)
    except Exception as e:
        print('An error occurred during a job request.', file=sys.stderr)
        print(e, file=sys.stderr)
    finally:
        conn.close()
        if (curs):
            curs.close()

if __name__ == '__main__':
    my_job_ids = list(map(int, sys.argv[1].split(',')))
    next_job_payload = sys.stdin.readline().replace('\n', '')
    create_jobs(my_job_ids, next_job_payload)

import __future__  # Likely used for print to support the sys.stderr method.
import psycopg2
import sys
from mcr_connections import make_job_queue_connection  # `.mcr_connections` returns: "not recognized as package" error.


def create_jobs(my_job_id, next_job_payload):
    conn = make_job_queue_connection()
    curs = None
    try:
        curs = conn.cursor()
        query = "CALL create_jobs(ARRAY[{}], '{}');".format(','.join(str(x) for x in my_job_id), next_job_payload)
        curs.execute(query)
        conn.commit()
    except psycopg2.OperationalError as e:
        print('A "psycopg2.OperationalError" is fired on CREATE_JOBS operation!'
              ' This is unexpected... The following error msg is associated:\n{}'.format(e), file=sys.stderr)
    except Exception as e:
        print('An error occurred during a job request! Error:\n{}'.format(e), file=sys.stderr)
    finally:
        if curs:
            curs.close()
        conn.close()


if __name__ == '__main__':
    my_job_ids = list(map(int, sys.argv[1].split(',')))
    followup_payload = sys.stdin.readline().replace('\n', '')
    create_jobs(my_job_ids, followup_payload)

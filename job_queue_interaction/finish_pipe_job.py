import __future__  # Likely used for print to support the sys.stderr method.
import psycopg2
import sys
from mcr_connections import make_job_queue_connection  # `.mcr_connections` returns: "not recognized as package" error.


def mark_pipe_job_finished(job_ids, pipe_job_id):
    conn = make_job_queue_connection()
    curs = None
    try:
        curs = conn.cursor()
        query = "CALL finish_pipe(ARRAY[{}], '{}');".format(','.join(str(x) for x in job_ids), pipe_job_id)
        curs.execute(query)
        conn.commit()
    except psycopg2.OperationalError as e:
        print('A "psycopg2.OperationalError" is fired on FINISH_PIPE operation!'
              ' This is unexpected... The following error msg is associated:\n{}'.format(e), file=sys.stderr)
    except Exception as e:
        print('An error occurred during a job request. Error:\n{}'.format(e), file=sys.stderr)
    finally:
        if curs:
            curs.close()
        conn.close()


if __name__ == '__main__':
    my_job_ids = list(map(int, sys.argv[1].split(',')))
    my_pipe_job_id = sys.argv[2]
    mark_pipe_job_finished(my_job_ids, my_pipe_job_id)

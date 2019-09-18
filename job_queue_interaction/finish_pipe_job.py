from mcr_connections import make_job_queue_connection
#import psycopg2.extensions
import sys

def mark_pipe_job_finished(job_ids, pipe_job_id):
    conn = make_job_queue_connection()
    curs = None
    try:
        curs = conn.cursor()
        query = "CALL finish_pipe(ARRAY[{}], '{}');".format(','.join(str(x) for x in job_ids), pipe_job_id)
        curs.execute(query)
        conn.commit()
    except psycopg2.OperationalError as e:
        sys.stderr.write('A "psycopg2.OperationalError" is fired on FINISH_PIPE operation! This is unexpected... The following error msg is associated:')
        sys.stderr.write(e)
    except Exception as e:
        sys.stderr.write('An error occurred during a job request.')
        sys.stderr.write(e)
    finally:
        if (conn):
            curs.close()
            conn.close()


if __name__ == '__main__':
    my_job_ids = list(map(int, sys.argv[1].split(',')))
    pipe_job_id = sys.argv[2]
    mark_pipe_job_finished(my_job_ids, pipe_job_id)

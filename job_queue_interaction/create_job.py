import __future__  # Likely used for print to support the sys.stderr method.
import psycopg2
import sys
import os
from datetime import datetime
import json
import hashlib

from mcr_connections import make_job_queue_connection  # `.mcr_connections` returns: "not recognized as package" error.


def create_jobs(my_job_id, next_job_payload):
    conn = make_job_queue_connection()
    curs = None
    try:
        curs = conn.cursor()
        # Expects the job_id's of the current processed job and the payload(s) for the job(s) to create. Multiple
        # payloads must be captured in a json list, so that 1 single string can be passed through.
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

        hash_object = hashlib.md5(next_job_payload.encode())  # Expects Bytes input.
        print(json.dumps({"level": "INFO", "timestamp": datetime.now().isoformat(),
                          "message": 'Created new jobs.', "payload_hash": hash_object.hexdigest(),
                          "current_job_id": my_job_id, "pipe_job_id": int(os.environ["PIPE_JOB_ID"]),
                          "process_name": os.environ["PROCESS_NAME"], "process_version": os.environ["PROCESS_VERSION"],
                          "uuid": os.environ["PROCESS_UUID"]}))


if __name__ == '__main__':
    my_job_ids = list(map(int, sys.argv[1].split(',')))
    followup_payload = sys.stdin.readline().replace('\n', '')
    create_jobs(my_job_ids, followup_payload)

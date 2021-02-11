import __future__
import sys
import re
import json
import os   # for environment vars
import flask
from flask import request, jsonify
import psycopg2
import psycopg2.extensions

app = flask.Flask(__name__)
app.config["DEBUG"] = True

os.environ["PGHOST"] = "host.docker.internal"
os.environ["PGUSER"] = "test_user"
os.environ["PGPASSWORD"] = "test_user"
os.environ["PGDATABASE"] = "single_procedure_job_queue"


def make_connection():
    # All details can be provided by environment variables.
    # Please see "https://www.postgresql.org/docs/9.3/libpq-envars.html" for details.
    return psycopg2.connect("")


def execute_query(query, to_filter, fetch_method):
    conn = make_connection()
    curs = None
    result = None
    try:
        curs = conn.cursor()
        curs.execute(query, to_filter)
        conn.commit()
        if fetch_method is 'all':
            result = curs.fetchall()
        elif fetch_method is 'one':
            result = curs.fetchone()

    # except KeyError as e:
    #     print('An error occurred when fetching the job request. Containing:\n{}'.format(e), file=sys.stderr)
    # except psycopg2.OperationalError as e:
    #     print('A "psycopg2.OperationalError" is fired. The following error msg is associated:\n{}'.format(e), file=sys.stderr)
    #     # return 'retry'
    except Exception as e:
        print('An error occurred during querying.', file=sys.stderr)
        print(e, file=sys.stderr)
        # This is not mandatory error handling, but provides us
        # with the construct to build our own proper error handling.
        if curs is not None:
            conn.rollback()

    finally:
        conn.close()
        if curs:
            curs.close()

    return result


# We can provide a user instruction when just calling the URL without any URI or parameter:
@app.route('/', methods=['GET'])
def home():
    return '''<h1>Requests interaction</h1>
<p>An API to launch and keep track of the different requests that has been fired.</p>'''


@app.errorhandler(404)
def page_not_found(e):
    return "<h1>404</h1><p>The resource could not be found.</p>", 404


# API call:
# 127.0.0.1:5000/api/v1/resources/requests?request_id=43
# or
# 127.0.0.1:5000/api/v1/resources/requests?request_type=dtf
@app.route('/api/v1/resources/requests', methods=['GET'])
def api_requests():
    req_id = request.args.get('request_id')
    req_type = request.args.get('request_type')

    query = "SELECT * FROM requests WHERE"
    to_filter = []

    if req_id and req_type:
        return page_not_found(404)
    if req_id:
        query += ' request_id=%1.0f;'
        to_filter.append(req_id)
    if req_type:
        query += ' request_type=%s;'
        to_filter.append(req_type)

    results = execute_query(query, to_filter, fetch_method='all')

    return jsonify(results)


# API call:
# Including your JSON payload with a POST call to this URL
# 127.0.0.1:5000/api/v1/resources/requests/createRequest/dtf/dtf:1.0.1
#
@app.route('/api/v1/resources/requests/createRequest/<req_type>/<pipe_name_version>', methods=['POST'])
def api_fire_request(req_type, pipe_name_version):
    # 2 values are provided as part of the URL.
    # Get json data that was send over using the POST method:
    req_data = request.get_json()

    # The priority can additionally be set with the 'query parameters'. e.g. `/dtf/dtf:1.0.1?priority:500`
    # I did notice that it is probably not that orthodox to do...
    priority = request.args.get('priority')
    if not priority:
        priority = 100

    # DEBUG CODE:
    # return """<h1>req_type is: {}</h1>
    # <h1>pipe_name_version is: {}</h1>
    # <h1>priority is: {}</h1>
    # <h1>job_payload is: {}</h1>
    # <h1>url is: {}</h1>
    # """.format(req_type, pipe_name_version, priority, req_data, request.url)

    if req_type.lower() == 'dtf':
        if re.match(r'dtf:.+', pipe_name_version.lower()):
            pipe_name, pipe_version = pipe_name_version.split(':')
            execute_query('insert into requests ('
                          'request_type, request_operations, request_payload, request_priority'
                          ') values (%s, %s::jsonb, %s, %s);',
                          ['DTF', json.dumps([{"name": pipe_name.upper(), "version": pipe_version}]), req_data, priority],
                          fetch_method=None)
        else:
            print("No pipelines other then the 'dtf:...' pipelines are supported yet.", file=sys.stderr)
            return page_not_found(404)
    else:
        print("No pipelines other then the 'dtf:...' pipelines are supported yet.", file=sys.stderr)
    return 200


@app.route('/api/v1/resources/results/<metadata_or_content>', methods=['GET'])
def api_results(metadata_or_content):
    req_id = request.args.get('request_id')

    if not req_id or metadata_or_content not in ['metadata', 'content']:
        return page_not_found(404)

    if metadata_or_content == 'metadata':
        result_meta = execute_query("SELECT result_id, request_id, result_timestamp, "
                                    "MD5(result_content) as result_content_hash FROM results_dtf "
                                    "WHERE request_id = %s;",
                                    [req_id], fetch_method='all')

        request_info = execute_query("SELECT * FROM requests WHERE request_id = %s;", [req_id], fetch_method='one')

        results = {"request": request_info, "results_metadata": result_meta}
    else:  # if requesting 'content'
        results = execute_query("SELECT * FROM results_dtf WHERE request_id = %s "
                                "ORDER BY result_timestamp DESC LIMIT 1;", [req_id], fetch_method='one')

    return jsonify(results)


# API call:
# 127.0.0.1:5000/api/v1/resources/job/status?request_id=23
#
# Expected outcome:
# [
#   {
#     "request_id": 43,
#     "n_results_present": 0,
#     "pipe_job_id": 19,
#     "pipe_id": 99,
#     "status_total_perc": 33.3,
#     "statuses": {
#       "dtf_meta": 100.0,
#       "dtf_summarize": 0.0,
#       "dtf_combine_upload": 0.0
#     },
#     "processes": [
#       {
#         "name": "dtf_meta",
#         "version": "3.4.0",
#         "order_nr": 1,
#         "n_jobs_expected": 1,
#         "n_jobs_created": 1,
#         "n_jobs_assigned": 1,
#         "n_jobs_finished": 1
#       },
#       {
#         "name": "dtf_summarize",
#         "version": "3.4.0",
#         "order_nr": 2,
#         "n_jobs_expected": 1,
#         "n_jobs_created": 0,
#         "n_jobs_assigned": 0,
#         "n_jobs_finished": 0
#       },
#       {
#         "name": "dtf_combine_upload",
#         "version": "3.4.0",
#         "order_nr": 3,
#         "n_jobs_expected": 1,
#         "n_jobs_created": 0,
#         "n_jobs_assigned": 0,
#         "n_jobs_finished": 0
#       }
#     ]
#   }
# ]
#
@app.route('/api/v1/resources/jobs/status', methods=['GET'])
def get_job_status():
    # Obtain query parameters
    request_id = request.args.get('request_id')
    pipe_job_id = request.args.get('pipe_job_id')

    if (bool(request_id) + bool(pipe_job_id)) != 1:
        print("job status filtering can only be performed with 1 filter simultaneously.", file=sys.stderr)
        return page_not_found(404)

    if request_id:
        query = 'SELECT pipe_job_id FROM pipe_job_queue WHERE request_id = %s;'
        pipe_jobs = execute_query(query, [request_id], fetch_method='all')
        pipe_job_ids = [x[0] for x in pipe_jobs]
    else:
        pipe_job_ids = [pipe_job_id]

    results = []
    for iPipe_job in pipe_job_ids:
        query = '''SELECT pipe_job_id, pipe_id, job_process_name, job_process_version, 
                job_finished, (Job_Assigned_Process_uuid = '') IS NOT FALSE
                FROM job_queue WHERE pipe_job_id = %s;'''

        jobs = execute_query(query, [iPipe_job], fetch_method='all')

        if not jobs:
            continue
        pipe_id = jobs[0][1]

        query = 'SELECT process_name, process_version, process_order FROM pipeline_processes WHERE pipe_id = %s;'
        pipe_job_processes = execute_query(query, [(pipe_id)], fetch_method='all')

        # sort the processes by order
        if pipe_job_processes:
            pipe_job_processes.sort(key=lambda x: x[2])

        results_proc = []
        for iProc in pipe_job_processes:

            # Find all jobs for this process and version. No jobs (yet) result in an empty list.
            related_jobs = [x for x in jobs if x[2] == iProc[0] and x[3] == iProc[1]]

            results_proc.append({
                "name": iProc[0],
                "version": iProc[1],
                "order_nr": iProc[2],
                "n_jobs_expected": max(len(related_jobs), 1),
                "n_jobs_created": len(related_jobs),
                "n_jobs_assigned": sum([not x[5] for x in related_jobs]),
                "n_jobs_finished": sum([x[4] for x in related_jobs if x[4] is not None])  # sums logical 'job_finished' flags
            })

        # Check if results are available:
        query = 'SELECT result_id FROM results_dtf WHERE request_id = %s;'
        db_results_dtf = execute_query(query, [request_id], fetch_method='all')

        # Compose the metadata of this pipe_job and append detailed process data:
        results.append({
            "request_id": request_id,
            "n_results_present": len(db_results_dtf),
            "pipe_job_id": iPipe_job,
            "pipe_id": pipe_id,
            "status_total_perc": round((sum([x['n_jobs_finished'] for x in results_proc]) /
                                  sum([x['n_jobs_expected'] for x in results_proc])) * 100, 1), # 1 dec rounding
            "statuses": {x['name']:  # dynamic tuple assignment. << the keys  vv the values
                             round((x['n_jobs_finished']/x['n_jobs_expected']*100)) for x in results_proc},
            "processes": results_proc
        })

    return jsonify(results)


app.run()

import psycopg2

def make_job_queue_connection():
    # All details can be provided by environment variables.
    # Please see "https://www.postgresql.org/docs/9.3/libpq-envars.html" for details.
    return psycopg2.connect("")

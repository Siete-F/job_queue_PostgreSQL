import psycopg2


def make_job_queue_connection():
    # All details can be provided by environment variables.
    # Please see "https://www.postgresql.org/docs/9.3/libpq-envars.html" for details.
    # In this case they must likely be provided in a `.env` file like: `PGHOST=host.docker.internal` etc.
    return psycopg2.connect("")

FROM python:3.7

# define the two arguments that can be provided using:
# `docker build --build-arg PROCESS_NAME=shittool --build-arg PROCESS_VERSION=1.0.0 .`
# These values will form the new defaults for the process to use as name and version.
ARG PROCESS_NAME
ARG PROCESS_VERSION

# Please provide password and username using PGPASSWORD and PGUSER (see https://www.postgresql.org/docs/9.1/libpq-envars.html) in an .env file in the current folder and load it using `docker build --env-file .env`

COPY requirements.txt /tmp/

RUN pip install -r /tmp/requirements.txt

# Prohibit ROOT access
RUN useradd --create-home appuser
WORKDIR /home/appuser
USER appuser

# Less time is required to rebuild the container if the most changing container parts are placed at the bottom.
COPY example_process.py /

ENV PROCESS_NAME    ${PROCESS_NAME:-first_process}
ENV PROCESS_VERSION ${PROCESS_VERSION:-1.9.2}

CMD [ "python", "/example_process.py" ]

# Alternative approach to the `requirements.txt` file:

# # Fix the line endings of the 'activate' script (or it will puke it's guts out on your docker build)
# RUN sed -i 's/\r//' /microservice/venv/Scripts/activate
# 
# # Make the venv environment active
# RUN /microservice/venv/Scripts/activate

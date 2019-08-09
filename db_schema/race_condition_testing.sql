-- create new db
create user test_user with encrypted password 'test_user';
------------------------------------
create database simultanious_job_pickup_test ;
ALTER database simultanious_job_pickup_test OWNER TO test_user;
GRANT all ON DATABASE simultanious_job_pickup_test TO test_user;

------------------------------------------------------------------------------------------------
-- Simultanious job pickup test --
------------------------------------------------------------------------------------------------

CREATE TABLE job_queue_pickup_test (
    sample_id            serial PRIMARY KEY,
    process_name         varchar(12) DEFAULT NULL
);


CREATE TABLE job_queue_pickup_count (
    process_name         varchar(12) PRIMARY KEY,
    Timestamp            TIMESTAMP DEFAULT current_timestamp,
    count                INTEGER DEFAULT 0
);

CREATE TABLE job_queue_pickup_race (
    sample_ids           integer ARRAY PRIMARY KEY,
    process_name         varchar(12),
    Timestamp            TIMESTAMP DEFAULT current_timestamp
);

-- Perform the following to initiate OR reset the test.
-- 1) Run this chunk below to reset the tables above.
-- 2) Then run `Mock Data Generator` on `job_queue_pickup_test` with 2000 records, removing old data, setting process_name on NULL.
TRUNCATE TABLE job_queue_pickup_race;
TRUNCATE TABLE job_queue_pickup_count;
insert into job_queue_pickup_count (process_name) values 
   ('process_1'),('process_2'),('process_3'),('process_4'),('TESTING');

   
----- The check, values should be equal:

SELECT C.process_name, R.count AS real_count, C.count AS comsumed_count FROM job_queue_pickup_count C JOIN (SELECT process_name, count(*) FROM job_queue_pickup_test GROUP BY process_name ORDER BY process_name) AS R ON C.process_name = R.process_name ORDER BY process_name;




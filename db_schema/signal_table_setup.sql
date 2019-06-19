create type EnumSensorTypes      as enum ('Accelerometer', 'Gyroscope', 'Magnetometer', 'Presure');
create type EnumSensorDirections as enum ('MedioLateral', 'DorsalVentral', 'CaudalCranial', 'None');

-- small table with a constant set of values:
create table SensorTypes (
    SensorId        smallint             not null primary key,
    SensorType      EnumSensorTypes      not null, -- Assigning it the created 'ENUM' type.
    SensorDirection EnumSensorDirections not null  -- Assigning it the created 'ENUM' type.
);

create table SensorData (
    MeasurementId  int         not null,
    Timestamp      timestamptz not null,
    SensorId       smallint    not null references SensorTypes(SensorId),
    SensorValue    numeric(8,4),
   constraint sample primary key(MeasurementId, Timestamp, SensorId)
);


------------------------------------------------------------------------------------
create type EnumSensorTypes      as enum ('Accelerometer', 'Gyroscope', 'Magnetometer', 'Presure');
create type EnumSensorDirections as enum ('MedioLateral', 'DorsalVentral', 'CaudalCranial', 'None');

create table SampleTime (
    SampleId       int         not null primary key,
    MeasurementId  int         not null,
    Timestamp      timestamptz not null  -- per timestamp, there are at least 1 and at most 3 values per sensor type.
);

-- small table with a constant set of values:
create table SensorTypes (
    SensorId        SMALLINT             not null primary key,
    SensorType      EnumSensorTypes      not null, -- Assigning it the created 'ENUM' type.
    SensorDirection EnumSensorDirections not null  -- Assigning it the created 'ENUM' type.
);

create table SensorData (
    SampleId      int      not null references SampleTime(SampleId), -- Per timestamp and
    SensorId      smallint not null references SensorTypes(SensorId),  -- per sensor type/axis there is 1 value.
    SensorValue   numeric(8,4),
    constraint pkey primary key(SampleId, SensorId)
);


------------------------------------------------------------------------------------------------
-- We do have some more additional information that might bring us the last mile.
-- The SensorType and SensorDirection are not related in the way that was suggested in the previous example.
-- There is a timestamp per measurement and per sensor type (not sensor axis)
-- I think the search speed can be improved by placing the sensor_type with the measurement_id.

create type EnumSensorTypes      as enum ('Accelerometer', 'Gyroscope', 'Magnetometer', 'Pressure');
create type EnumSensorDirections as enum ('MedioLateral', 'DorsalVentral', 'CaudalCranial', 'None');

create table SensorSampleTime (
    SampleId       int             not null primary key,
    MeasurementId  int             not null,
    SensorType     EnumSensorTypes not null,
    Timestamp      timestamptz     not null
);

create table SensorData (
    SampleId        int                  not null references SensorSampleTime(SampleId),
    SensorDirection EnumSensorDirections not null,
    SampleValue     numeric(8,4),
    constraint pkey primary key(SampleId, SensorDirection)
);


------------------------------------------------------------------------------------------------

CREATE TABLE sizetest (id NUMERIC(8,4));
insert into sizetest values (1234.1234);
SELECT pg_total_relation_size('sizetest')



CREATE TABLE SensorAccelerometer (
	sample_id            bigserial ,
    MeasurementId        uuid NOT NULL,
    Timestamp            TIMESTAMPTZ not null,
    SignalMedioLateral   NUMERIC(8,4),
    SignalCaudalCranial  NUMERIC(8,4),
    SignalDorsalVentral  NUMERIC(8,4),
    constraint AccPKey primary key(sample_id, MeasurementId)
) PARTITION BY RANGE (MeasurementID);

CREATE TABLE SensorGyroscope (
	sample_id            bigserial,
    MeasurementId        uuid not null,
    Timestamp            TIMESTAMPTZ not null,
    SignalMedioLateral   NUMERIC(8,4),
    SignalCaudalCranial  NUMERIC(8,4),
    SignalDorsalVentral  NUMERIC(8,4),
    constraint GyrPKey primary key(sample_id, MeasurementId)
) PARTITION BY RANGE (MeasurementId);

CREATE TABLE SensorMagnetometer (
	sample_id            bigserial,
    MeasurementId        uuid not null,
    Timestamp            TIMESTAMPTZ not null,
    SignalMedioLateral   NUMERIC(8,4),
    SignalCaudalCranial  NUMERIC(8,4),
    SignalDorsalVentral  NUMERIC(8,4),
    constraint MagPKey primary key(sample_id, MeasurementId)
) PARTITION BY list (MeasurementID);

CREATE TABLE meas1 PARTITION OF SensorMagnetometer FOR VALUES IN (1);
CREATE TABLE meas2 PARTITION OF SensorMagnetometer FOR VALUES IN (2);
CREATE TABLE meas3 PARTITION OF SensorMagnetometer FOR VALUES IN (3);
CREATE TABLE meas4 PARTITION OF SensorMagnetometer FOR VALUES IN (4);
CREATE TABLE meas5 PARTITION OF SensorMagnetometer FOR VALUES IN (5);
CREATE TABLE meas6 PARTITION OF SensorMagnetometer FOR VALUES IN (6);
select COUNT(*) from meas1;
INSERT INTO SensorMagnetometer VALUES (1, '15-08-1990 10:11:12.1234', 1234.846, 1864.215, 1.56),
                                      (2, '02-08-1990 13:14:15.987',  5.846,       9.215, 1.56),
                                      (2, '02-08-1990 13:14:15.987',  5.846,       9.215, 1.56),
                                      (2, '02-08-1990 13:14:15.987',  5.846,       9.215, 1.56),
                                      (2, '02-08-1990 13:14:15.987',  5.846,       9.215, 1.56),
                                      (2, '02-08-1990 13:14:15.987',  5.846,       9.215, 1.56),
                                     ;

-- All data can now be obtained in 2 ways:
--- Querying the original table:
SELECT * FROM SensorMagnetometer;
SELECT * FROM SensorMagnetometer WHERE measurementid = 2;

--- Or by using the created partition:
-- Obtains measurement 691a6ee0901296bada54
SELECT * FROM hash_c6s5few651f6e8;
-- Obtains measurement 691a6ee0901296bada54 (or MeasurementId
SELECT * FROM hash_691a6ee0901296bada54;

-- It is also possible to create a 'remaining' partition. Now every inserted measurement can be inserted.
CREATE TABLE remainingMagSensordata PARTITION OF SensorMagnetometer DEFAULT;

INSERT INTO SensorMagnetometer VALUES (10, '15-08-1990 10:11:12.1234', 1234.846, 1864.215, 1.56)

begin;
CREATE TABLE hash_c6s5few651f6e8 PARTITION OF SensorMagnetometer FOR VALUES IN (22);
INSERT INTO SensorMagnetometer VALUES (22, '15-08-1990 10:11:12.1234', 1234.846, 1864.215, 1.56);
commit;

CREATE TABLE SensorPressure (
    MeasurementId        INT NOT NULL,
    Timestamp            TIMESTAMPTZ not null,
    Signal               NUMERIC(8,4),
    constraint PressPKey primary key(MeasurementId, Timestamp)
) PARTITION BY RANGE (MeasurementID);


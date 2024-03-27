--
-- PostgreSQL database dump
--

-- Dumped from database version 13.11 (Debian 13.11-0+deb11u1)
-- Dumped by pg_dump version 13.11 (Debian 13.11-0+deb11u1)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

CREATE PROCEDURE public.in_plunge_window()
    LANGUAGE sql
    AS $$
    SELECT CASE WHEN plunge_start>=now() AND plunge_end<=now() THEN 1 ELSE 0 END, value_inc_vat
    FROM plunges
    WHERE plunge_start>=now() AND plunge_end<=now();
$$;

SET default_tablespace = '';
SET default_table_access_method = heap;

CREATE TABLE public.plunges (
    plunge_start timestamp with time zone,
    plunge_end timestamp with time zone,
    value_inc_vat double precision
);

CREATE TABLE public.preferred_mode_times (
    start_time time without time zone,
    finish_time time without time zone,
    inverter_mode character varying
);

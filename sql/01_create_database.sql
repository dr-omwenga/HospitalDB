-- ============================================================
-- Script  : 01_create_database.sql
-- Purpose : Create the HospitalDB database
-- Date    : 2026-05-07
-- ============================================================

USE master;
GO

IF DB_ID('HospitalDB') IS NULL
    CREATE DATABASE HospitalDB;
GO

USE HospitalDB;
GO

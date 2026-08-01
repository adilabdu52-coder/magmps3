-- MAGPMS install 1 of 35 - run IN ORDER, one at a time.
-- Project: fendopitdcyoefpxuevd
-- No begin/commit: a transaction split across files rolls back.
set search_path = public, extensions;

create schema if not exists extensions;

set search_path = public, extensions;

create extension if not exists pgcrypto with schema extensions;

create table if not exists staff (
  id            uuid primary key default gen_random_uuid(),
  full_name     text,
  username      text,
  phone         text,
  email         text,
  role          text default 'operator',
  status        text default 'pending',
  created_at    timestamptz not null default now());

create table if not exists tanks (
  id              serial primary key,
  tank_name       text,
  fuel_type       text,
  capacity_liters numeric,
  current_liters  numeric default 0);

create table if not exists credit_customers (
  id           uuid primary key default gen_random_uuid(),
  name         text,
  phone        text,
  plate_no     text,
  credit_limit numeric default 0,
  balance      numeric default 0);

create table if not exists sales (
  id                 uuid primary key default gen_random_uuid(),
  staff_id           uuid references staff(id),
  fuel_type          text,
  liters             numeric,
  total_etb          numeric,
  payment_method     text,
  credit_customer_id uuid references credit_customers(id),
  voided             boolean default false,
  created_at         timestamptz not null default now());

create table if not exists fuel_prices (
  id              uuid primary key default gen_random_uuid(),
  fuel_type       text,
  price_per_liter numeric);

create table if not exists shifts (
  id            uuid primary key default gen_random_uuid(),
  staff_id      uuid references staff(id),
  opening_meter numeric,
  closing_meter numeric,
  opened_at     timestamptz,
  closed_at     timestamptz);

create table if not exists attendance (
  id        uuid primary key default gen_random_uuid(),
  staff_id  uuid references staff(id),
  check_in  timestamptz,
  check_out timestamptz);

create table if not exists expenses (
  id          uuid primary key default gen_random_uuid(),
  category    text,
  description text,
  amount_etb  numeric,
  created_at  timestamptz not null default now());

create table if not exists deliveries (
  id          uuid primary key default gen_random_uuid(),
  tank_id     int references tanks(id),
  liters      numeric,
  note        text,
  recorded_by uuid references staff(id),
  created_at  timestamptz not null default now());

alter table staff add column if not exists auth_user_id uuid unique references auth.users(id) on delete set null;

alter table staff add column if not exists email  text;

alter table staff add column if not exists phone  text;

alter table staff add column if not exists role   text;

alter table staff add column if not exists status text;

update staff set role   = 'operator' where role   is null;

-- BCTN: Banco Central de Terra Nova
-- Execute este arquivo inteiro no SQL Editor do seu projeto Supabase.

create extension if not exists pgcrypto;

create table if not exists public.profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null check (char_length(display_name) between 2 and 40),
  created_at timestamptz not null default now()
);

create table if not exists public.accounts (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null unique references auth.users(id) on delete cascade,
  pix_key text not null unique,
  balance numeric(14,2) not null default 0 check (balance >= 0),
  currency text not null default 'TN$' check (currency = 'TN$'),
  created_at timestamptz not null default now()
);

create table if not exists public.transfers (
  id uuid primary key default gen_random_uuid(),
  sender_account_id uuid not null references public.accounts(id),
  recipient_account_id uuid not null references public.accounts(id),
  amount numeric(14,2) not null check (amount > 0),
  description text not null default '',
  created_at timestamptz not null default now(),
  check (sender_account_id <> recipient_account_id)
);

create index if not exists transfers_sender_idx
  on public.transfers(sender_account_id, created_at desc);
create index if not exists transfers_recipient_idx
  on public.transfers(recipient_account_id, created_at desc);

alter table public.profiles enable row level security;
alter table public.accounts enable row level security;
alter table public.transfers enable row level security;

drop policy if exists "profile is visible to owner" on public.profiles;
create policy "profile is visible to owner"
on public.profiles for select to authenticated
using (auth.uid() = user_id);

drop policy if exists "account is visible to owner" on public.accounts;
create policy "account is visible to owner"
on public.accounts for select to authenticated
using (auth.uid() = owner_id);

drop policy if exists "transfer history is visible to participants" on public.transfers;
create policy "transfer history is visible to participants"
on public.transfers for select to authenticated
using (
  exists (select 1 from public.accounts a
          where a.id = sender_account_id and a.owner_id = auth.uid())
  or
  exists (select 1 from public.accounts a
          where a.id = recipient_account_id and a.owner_id = auth.uid())
);

-- Cria perfil, conta e chave fictícia automaticamente no cadastro.
create or replace function public.handle_new_bctn_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  chosen_name text;
  chosen_key text;
begin
  chosen_name := coalesce(
    nullif(trim(new.raw_user_meta_data ->> 'display_name'), ''),
    'Jogador'
  );

  insert into public.profiles(user_id, display_name)
  values (new.id, left(chosen_name, 40));

  loop
    chosen_key := 'TN' || upper(encode(gen_random_bytes(5), 'hex'));
    exit when not exists (
      select 1 from public.accounts where pix_key = chosen_key
    );
  end loop;

  insert into public.accounts(owner_id, pix_key, balance)
  values (new.id, chosen_key, 0);

  return new;
end;
$$;

drop trigger if exists on_auth_user_created_bctn on auth.users;
create trigger on_auth_user_created_bctn
after insert on auth.users
for each row execute procedure public.handle_new_bctn_user();

-- Transferência atômica: valida saldo, bloqueia as contas e registra o extrato.
create or replace function public.bctn_transfer(
  recipient_key text,
  transfer_amount numeric,
  transfer_description text default ''
)
returns table (
  transfer_id uuid,
  new_balance numeric,
  recipient_name text
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  sender_id uuid;
  recipient_id uuid;
  sender_user uuid;
  recipient_user uuid;
  sender_balance numeric(14,2);
  clean_amount numeric(14,2);
  new_transfer_id uuid;
  target_name text;
begin
  if auth.uid() is null then
    raise exception 'Você precisa entrar na sua conta.';
  end if;

  clean_amount := round(transfer_amount, 2);
  if clean_amount is null or clean_amount <= 0 or clean_amount > 1000000 then
    raise exception 'Valor de transferência inválido.';
  end if;

  select a.id, a.owner_id
    into sender_id, sender_user
  from public.accounts a
  where a.owner_id = auth.uid();

  if sender_id is null then
    raise exception 'Conta de origem não encontrada.';
  end if;

  select a.id, a.owner_id
    into recipient_id, recipient_user
  from public.accounts a
  where a.pix_key = upper(trim(recipient_key));

  if recipient_id is null then
    raise exception 'Chave TN$ não encontrada.';
  end if;

  if sender_id = recipient_id then
    raise exception 'Não é possível transferir para sua própria conta.';
  end if;

  -- Bloqueia ambas em ordem estável para evitar corrida entre transferências.
  perform a.id
  from public.accounts a
  where a.id in (sender_id, recipient_id)
  order by a.id
  for update;

  select a.balance into sender_balance
  from public.accounts a where a.id = sender_id;

  if sender_balance < clean_amount then
    raise exception 'Saldo insuficiente.';
  end if;

  update public.accounts
    set balance = balance - clean_amount
    where id = sender_id;

  update public.accounts
    set balance = balance + clean_amount
    where id = recipient_id;

  insert into public.transfers(
    sender_account_id, recipient_account_id, amount, description
  ) values (
    sender_id, recipient_id, clean_amount, left(coalesce(transfer_description, ''), 100)
  ) returning id into new_transfer_id;

  select p.display_name into target_name
  from public.profiles p where p.user_id = recipient_user;

  return query
  select new_transfer_id,
         (sender_balance - clean_amount),
         coalesce(target_name, 'Conta BCTN');
end;
$$;

revoke all on function public.bctn_transfer(text, numeric, text) from public;
grant execute on function public.bctn_transfer(text, numeric, text) to authenticated;

-- Usuários não podem alterar saldo, chave ou transferências diretamente.
revoke insert, update, delete on public.accounts from anon, authenticated;
revoke insert, update, delete on public.transfers from anon, authenticated;
revoke insert, update, delete on public.profiles from anon, authenticated;
grant select on public.accounts, public.transfers, public.profiles to authenticated;

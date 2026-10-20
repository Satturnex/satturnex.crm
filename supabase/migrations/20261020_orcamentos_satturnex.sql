-- Satturnex CRM | Módulo de orçamentos comerciais
-- Compatível com o schema deste projeto: workspaces, workspace_members,
-- leads, auth.users e public.is_workspace_member(uuid).
-- Execute manualmente no Supabase Dashboard > SQL Editor. Não executar em produção
-- antes de revisar. Este arquivo não cria clientes/usuários fictícios.

begin;

-- ETAPA 1: funções de autorização. SECURITY DEFINER evita RLS recursiva em
-- workspace_members e o search_path fixo evita resolução por schemas externos.
create or replace function public.is_workspace_admin(target_workspace uuid)
returns boolean language sql stable security definer set search_path=public,pg_temp as $$
  select exists(select 1 from public.workspace_members m
    where m.workspace_id=target_workspace and m.user_id=auth.uid() and m.role in ('OWNER','ADMIN'));
$$;
revoke all on function public.is_workspace_admin(uuid) from public,anon;
grant execute on function public.is_workspace_admin(uuid) to authenticated;

create sequence if not exists public.quote_number_seq;

-- ETAPA 2: configurações comerciais e catálogo. Um registro de configuração
-- por workspace. Valores são internos e não fazem parte do PDF público.
create table if not exists public.quote_settings (
  workspace_id uuid primary key references public.workspaces(id) on delete cascade,
  currency text not null default 'BRL' check(currency ~ '^[A-Z]{3}$'),
  sales_discount_limit_percent numeric(5,2) not null default 0 check(sales_discount_limit_percent between 0 and 100),
  default_validity_days integer not null default 15 check(default_validity_days between 1 and 365),
  margin_floor_percent numeric(5,2) not null default 0 check(margin_floor_percent between 0 and 100),
  split_basis text not null default 'net_revenue' check(split_basis in ('net_revenue','gross_revenue','project_result')),
  company_name text not null default 'Satturnex', company_document text, company_email text, company_phone text,
  company_address text, commercial_intro text, created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);

create table if not exists public.service_catalog (
  id uuid primary key default gen_random_uuid(), workspace_id uuid not null references public.workspaces(id) on delete cascade,
  name text not null check(length(trim(name))>0), category text not null,
  description text not null default '', internal_description text not null default '', unit text not null default 'unidade',
  reference_price numeric(12,2) not null default 0 check(reference_price>=0),
  minimum_price numeric(12,2) not null default 0 check(minimum_price>=0),
  estimated_cost numeric(12,2) not null default 0 check(estimated_cost>=0),
  additional_days integer not null default 0 check(additional_days>=0), recurring boolean not null default false,
  periodicity text, technical_evaluation_required boolean not null default false,
  active boolean not null default true, created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  unique(workspace_id,name), check(not recurring or periodicity is not null)
);

-- ETAPA 3: proposta e retrato comercial. quote_number gerado pelo banco para
-- evitar colisões concorrentes. Snapshot JSON mantém os dados do cliente/escopo.
create table if not exists public.quotes (
  id uuid primary key default gen_random_uuid(), workspace_id uuid not null references public.workspaces(id) on delete cascade,
  quote_number text not null default ('SAT-'||to_char(current_date,'YYYY')||'-'||lpad(nextval('public.quote_number_seq')::text,6,'0')),
  lead_id uuid references public.leads(id) on delete set null,
  project_name text not null check(length(trim(project_name))>0), need_summary text not null default '',
  client_snapshot jsonb not null default '{}'::jsonb, scope jsonb not null default '{}'::jsonb,
  owner text not null default '', status text not null default 'Rascunho' check(status in
   ('Rascunho','Pendente de avaliação técnica','Pendente de aprovação comercial','Pronto para envio','Enviado','Em negociação','Aprovado','Recusado','Expirado','Cancelado')),
  currency text not null default 'BRL' check(currency ~ '^[A-Z]{3}$'),
  total_amount numeric(12,2) not null default 0 check(total_amount>=0),
  development_amount numeric(12,2) not null default 0 check(development_amount>=0),
  recurring_amount numeric(12,2) not null default 0 check(recurring_amount>=0),
  discount_amount numeric(12,2) not null default 0 check(discount_amount>=0),
  third_party_included numeric(12,2) not null default 0 check(third_party_included>=0),
  third_party_direct numeric(12,2) not null default 0 check(third_party_direct>=0),
  estimated_direct_cost numeric(12,2) not null default 0 check(estimated_direct_cost>=0),
  valid_until date, sent_at timestamptz, sent_by uuid references auth.users(id) on delete set null,
  approved_at timestamptz, approved_by uuid references auth.users(id) on delete set null,
  approval_method text, created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  unique(workspace_id,quote_number), unique(id,workspace_id)
);

-- Liga projetos ao novo módulo sem alterar o vínculo antigo project.proposal_id.
alter table public.projects add column if not exists quote_id uuid;
do $$ begin
  if not exists(select 1 from pg_constraint where conname='projects_quote_workspace_fk' and conrelid='public.projects'::regclass) then
    alter table public.projects add constraint projects_quote_workspace_fk
      foreign key(quote_id,workspace_id) references public.quotes(id,workspace_id);
  end if;
end $$;
create unique index if not exists projects_workspace_quote_unique on public.projects(workspace_id,quote_id) where quote_id is not null;

create table if not exists public.quote_items (
  id uuid primary key default gen_random_uuid(), workspace_id uuid not null references public.workspaces(id) on delete cascade,
  quote_id uuid not null, catalog_id uuid references public.service_catalog(id) on delete set null,
  name text not null check(length(trim(name))>0), description text not null default '',
  quantity numeric(10,2) not null default 1 check(quantity>0), unit_price numeric(12,2) not null check(unit_price>=0),
  discount numeric(12,2) not null default 0 check(discount>=0), subtotal numeric(12,2) not null check(subtotal>=0),
  recurring boolean not null default false, periodicity text, estimated_cost numeric(12,2) not null default 0 check(estimated_cost>=0),
  internal_note text not null default '', technical_evaluation_required boolean not null default false, snapshot jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  constraint quote_items_quote_workspace_fk foreign key(quote_id,workspace_id) references public.quotes(id,workspace_id) on delete cascade,
  check(discount <= quantity*unit_price), check(not recurring or periodicity is not null)
);

-- A view pública expõe somente campos comerciais. Views administrativas incluem
-- os custos e notas internas e filtram as linhas pelo papel OWNER/ADMIN.
create or replace view public.service_catalog_public with (security_invoker=true) as
  select id,workspace_id,name,category,description,unit,reference_price,additional_days,recurring,periodicity,technical_evaluation_required,active,created_at,updated_at
  from public.service_catalog;
create or replace view public.service_catalog_admin with (security_barrier=true) as
  select id,workspace_id,name,category,description,internal_description,unit,reference_price,minimum_price,estimated_cost,additional_days,recurring,periodicity,technical_evaluation_required,active,created_by,created_at,updated_at
  from public.service_catalog where public.is_workspace_admin(workspace_id);
create or replace view public.quote_items_public with (security_invoker=true) as
  select id,workspace_id,quote_id,catalog_id,name,description,quantity,unit_price,discount,subtotal,recurring,periodicity,technical_evaluation_required,created_at
  from public.quote_items;
create or replace view public.quotes_public with (security_invoker=true) as
  select id,workspace_id,quote_number,lead_id,project_name,need_summary,client_snapshot,scope,owner,status,currency,total_amount,development_amount,recurring_amount,discount_amount,valid_until,sent_at,sent_by,approved_at,approved_by,approval_method,created_by,created_at,updated_at
  from public.quotes;
create or replace view public.quotes_admin with (security_barrier=true) as
  select id,workspace_id,quote_number,project_name,status,total_amount,discount_amount,third_party_included,third_party_direct,estimated_direct_cost,created_at
  from public.quotes where public.is_workspace_admin(workspace_id);

-- ETAPA 4: aprovações e eventos. Eventos são append-only por RLS.
create table if not exists public.quote_approvals (
  id uuid primary key default gen_random_uuid(), workspace_id uuid not null references public.workspaces(id) on delete cascade,
  quote_id uuid not null, requested_by uuid references auth.users(id) on delete set null,
  decided_by uuid references auth.users(id) on delete set null,
  reason text not null, decision text not null default 'pending' check(decision in ('pending','approved','rejected')),
  requested_at timestamptz not null default now(), decided_at timestamptz, decision_note text,
  constraint quote_approvals_quote_workspace_fk foreign key(quote_id,workspace_id) references public.quotes(id,workspace_id) on delete cascade
);
create table if not exists public.quote_events (
  id bigint generated always as identity primary key, workspace_id uuid not null references public.workspaces(id) on delete cascade,
  quote_id uuid not null, actor_id uuid references auth.users(id) on delete set null,
  event_type text not null, details jsonb not null default '{}'::jsonb, created_at timestamptz not null default now(),
  constraint quote_events_quote_workspace_fk foreign key(quote_id,workspace_id) references public.quotes(id,workspace_id) on delete cascade
);

-- ETAPA 5: índices das listagens e integridade multi-workspace.
create index if not exists quotes_workspace_created_idx on public.quotes(workspace_id,created_at desc);
create index if not exists quotes_workspace_status_idx on public.quotes(workspace_id,status,created_at desc);
create index if not exists quotes_workspace_lead_idx on public.quotes(workspace_id,lead_id);
create index if not exists quote_items_quote_idx on public.quote_items(quote_id,created_at);
create index if not exists quote_items_catalog_idx on public.quote_items(catalog_id);
create index if not exists service_catalog_workspace_active_idx on public.service_catalog(workspace_id,active,category);
create index if not exists quote_approvals_workspace_pending_idx on public.quote_approvals(workspace_id,decision,requested_at desc);
create index if not exists quote_events_quote_time_idx on public.quote_events(quote_id,created_at desc);

-- ETAPA 6: funções de proteção. Comerciais não podem publicar abaixo do mínimo
-- nem exceder o desconto autorizado sem decisão administrativa registrada.
create or replace function public.guard_quote_write() returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare admin_user boolean; s record; gross numeric; discount_total numeric; discount_pct numeric; margin_pct numeric; below_floor boolean; margin_low boolean; needs_approval boolean; technical_eval boolean;
begin
  admin_user := public.is_workspace_admin(new.workspace_id);
  if tg_op='UPDATE' and not admin_user then
    if old.workspace_id<>new.workspace_id or old.created_by is distinct from new.created_by or old.quote_number<>new.quote_number then
      raise exception 'Campos de propriedade do orçamento não podem ser alterados.' using errcode='42501';
    end if;
    if old.status in ('Aprovado','Recusado','Cancelado','Expirado') and new.status<>old.status then
      raise exception 'Este status é final e não pode ser reaberto por usuário comercial.' using errcode='42501';
    end if;
    if old.status is distinct from new.status and not (
      (old.status='Rascunho' and new.status in ('Pendente de avaliação técnica','Pendente de aprovação comercial','Pronto para envio','Cancelado')) or
      (old.status='Pendente de avaliação técnica' and new.status in ('Pendente de aprovação comercial','Pronto para envio','Cancelado')) or
      (old.status='Pendente de aprovação comercial' and new.status in ('Pronto para envio','Cancelado')) or
      (old.status='Pronto para envio' and new.status in ('Enviado','Cancelado')) or
      (old.status='Enviado' and new.status in ('Em negociação','Expirado','Cancelado')) or
      (old.status='Em negociação' and new.status in ('Expirado','Cancelado'))
    ) then raise exception 'Transição de status inválida.' using errcode='23514'; end if;
    if new.status in ('Pronto para envio','Enviado','Em negociação','Aprovado') and old.status in ('Pendente de aprovação comercial','Pendente de avaliação técnica') then
      raise exception 'A proposta exige aprovação administrativa antes deste status.' using errcode='42501';
    end if;
    if new.status in ('Aprovado','Recusado') then raise exception 'Somente administrador pode registrar decisão final no banco.' using errcode='42501'; end if;
  end if;
  select * into s from public.quote_settings where workspace_id=new.workspace_id;
  select coalesce(sum(discount),0),coalesce(sum(quantity*unit_price),0) into discount_total,gross
    from public.quote_items where quote_id=new.id;
  discount_pct := case when gross>0 then discount_total/gross*100 else 0 end;
  select exists(select 1 from public.quote_items i join public.service_catalog c on c.id=i.catalog_id
    where i.quote_id=new.id and i.workspace_id=new.workspace_id and i.unit_price<c.minimum_price) into below_floor;
  margin_pct:=case when gross-discount_total>0 then ((gross-discount_total-coalesce((select sum(estimated_cost*quantity) from public.quote_items where quote_id=new.id),0))/(gross-discount_total))*100 else 0 end;
  margin_low:=margin_pct<coalesce(s.margin_floor_percent,0);
  needs_approval := below_floor or margin_low or discount_pct>coalesce(s.sales_discount_limit_percent,0);
  select exists(select 1 from public.quote_items i where i.quote_id=new.id and i.technical_evaluation_required) into technical_eval;
  if technical_eval and not admin_user and new.status in ('Pronto para envio','Enviado','Em negociação','Aprovado') then
    raise exception 'A proposta exige avaliação técnica antes do envio.' using errcode='42501';
  end if;
  if not admin_user and needs_approval and new.status in ('Pronto para envio','Enviado','Em negociação','Aprovado') then
    raise exception 'Preço mínimo ou limite de desconto exige aprovação administrativa.' using errcode='42501';
  end if;
  if new.status='Aprovado' then new.approved_at=coalesce(new.approved_at,now());new.approved_by=coalesce(new.approved_by,auth.uid());end if;
  if new.status='Enviado' then new.sent_at=coalesce(new.sent_at,now());new.sent_by=auth.uid();end if;
  if tg_op='UPDATE' and new.status='Rascunho' and exists(select 1 from public.quote_items where quote_id=new.id) then
    if technical_eval then new.status='Pendente de avaliação técnica';
    elsif needs_approval then new.status='Pendente de aprovação comercial'; end if;
  end if;
  if tg_op='UPDATE' then
    select coalesce(sum(greatest(0,round(quantity*unit_price-discount,2))),0),
      coalesce(sum(case when recurring then greatest(0,round(quantity*unit_price-discount,2)) else 0 end),0),
      coalesce(sum(discount),0),coalesce(sum(quantity*unit_price),0),
      coalesce(sum(estimated_cost*quantity),0)
      into new.total_amount,new.recurring_amount,new.discount_amount,gross,new.estimated_direct_cost
      from public.quote_items where quote_id=new.id;
    new.development_amount:=greatest(0,new.total_amount-new.recurring_amount);
  end if;
  new.updated_at=now();return new;
end $$;
revoke all on function public.guard_quote_write() from public,anon,authenticated;

create or replace function public.guard_quote_item_write() returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare q_workspace uuid; q_status text; admin_user boolean; service_row record;
begin
  select workspace_id,status into q_workspace,q_status from public.quotes where id=coalesce(new.quote_id,old.quote_id);
  if q_workspace is null or q_workspace<>coalesce(new.workspace_id,old.workspace_id) then raise exception 'O item precisa pertencer ao mesmo workspace do orçamento.' using errcode='23503'; end if;
  admin_user:=public.is_workspace_admin(q_workspace);
  if not admin_user and q_status<>'Rascunho' then raise exception 'Somente rascunhos podem ter itens alterados.' using errcode='42501'; end if;
  if tg_op<>'DELETE' and new.catalog_id is not null then
    select * into service_row from public.service_catalog where id=new.catalog_id and workspace_id=q_workspace;
    if not found then raise exception 'O serviço do catálogo não pertence a este workspace.' using errcode='23503'; end if;
    if not admin_user then
      new.estimated_cost:=service_row.estimated_cost;
      new.internal_note:='';
      new.technical_evaluation_required:=service_row.technical_evaluation_required;
      new.snapshot:=jsonb_build_object('category',service_row.category);
    end if;
  elsif tg_op<>'DELETE' and not admin_user then
    new.estimated_cost:=0;new.internal_note:='';new.technical_evaluation_required:=false;new.snapshot:='{}'::jsonb;
  end if;
  if tg_op<>'DELETE' then new.subtotal:=greatest(0,round(new.quantity*new.unit_price-new.discount,2));end if;
  if tg_op='DELETE' then return old; else return new; end if;
end $$;
revoke all on function public.guard_quote_item_write() from public,anon,authenticated;

create or replace function public.log_quote_event() returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if tg_op='INSERT' then insert into public.quote_events(workspace_id,quote_id,actor_id,event_type,details) values(new.workspace_id,new.id,auth.uid(),'created',jsonb_build_object('status',new.status,'total',new.total_amount)); return new;
  elsif tg_op='UPDATE' then
    if old.status is distinct from new.status then
      insert into public.quote_events(workspace_id,quote_id,actor_id,event_type,details) values(new.workspace_id,new.id,auth.uid(),'status_changed',jsonb_build_object('from',old.status,'to',new.status));
      if new.status='Pendente de aprovação comercial' then
        insert into public.quote_approvals(workspace_id,quote_id,requested_by,reason,decision) values(new.workspace_id,new.id,auth.uid(),'Exceção comercial solicitada pela proposta.','pending');
      elsif old.status='Pendente de aprovação comercial' and new.status in ('Pronto para envio','Enviado','Aprovado') and public.is_workspace_admin(new.workspace_id) then
        insert into public.quote_approvals(workspace_id,quote_id,requested_by,decided_by,reason,decision,decided_at,decision_note)
          values(new.workspace_id,new.id,new.created_by,auth.uid(),'Aprovação de exceção comercial registrada pelo administrador.','approved',now(),'Status atualizado por administrador.');
      elsif old.status='Pendente de aprovação comercial' and new.status in ('Recusado','Cancelado') and public.is_workspace_admin(new.workspace_id) then
        insert into public.quote_approvals(workspace_id,quote_id,requested_by,decided_by,reason,decision,decided_at,decision_note)
          values(new.workspace_id,new.id,new.created_by,auth.uid(),'Exceção comercial recusada pelo administrador.','rejected',now(),'Status atualizado por administrador.');
      end if;
    end if;
    if old.total_amount is distinct from new.total_amount or old.discount_amount is distinct from new.discount_amount then insert into public.quote_events(workspace_id,quote_id,actor_id,event_type,details) values(new.workspace_id,new.id,auth.uid(),'values_changed',jsonb_build_object('old_total',old.total_amount,'new_total',new.total_amount,'old_discount',old.discount_amount,'new_discount',new.discount_amount)); end if;
    return new;
  end if; return null;
end $$;
revoke all on function public.log_quote_event() from public,anon,authenticated;

create or replace function public.log_quote_item_event() returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare qid uuid; wid uuid; begin qid=coalesce(new.quote_id,old.quote_id);wid=coalesce(new.workspace_id,old.workspace_id);
 insert into public.quote_events(workspace_id,quote_id,actor_id,event_type,details) values(wid,qid,auth.uid(),'item_'||lower(tg_op),jsonb_build_object('item_id',coalesce(new.id,old.id),'name',coalesce(new.name,old.name),'subtotal',coalesce(new.subtotal,old.subtotal)));
 if tg_op='DELETE' then return old; else return new; end if; end $$;
revoke all on function public.log_quote_item_event() from public,anon,authenticated;

create or replace function public.set_quote_updated_at() returns trigger language plpgsql set search_path=public,pg_temp as $$ begin new.updated_at=now();return new;end $$;

drop trigger if exists quote_guard_write on public.quotes;
create trigger quote_guard_write before insert or update on public.quotes for each row execute function public.guard_quote_write();
drop trigger if exists quote_event_log on public.quotes;
create trigger quote_event_log after insert or update on public.quotes for each row execute function public.log_quote_event();
drop trigger if exists quote_item_event_log on public.quote_items;
create trigger quote_item_event_log after insert or update or delete on public.quote_items for each row execute function public.log_quote_item_event();
drop trigger if exists quote_item_guard on public.quote_items;
create trigger quote_item_guard before insert or update or delete on public.quote_items for each row execute function public.guard_quote_item_write();
drop trigger if exists quote_settings_updated_at on public.quote_settings;
create trigger quote_settings_updated_at before update on public.quote_settings for each row execute function public.set_quote_updated_at();
drop trigger if exists service_catalog_updated_at on public.service_catalog;
create trigger service_catalog_updated_at before update on public.service_catalog for each row execute function public.set_quote_updated_at();
drop trigger if exists quotes_updated_at on public.quotes;
create trigger quotes_updated_at before update on public.quotes for each row execute function public.set_quote_updated_at();

-- Cria defaults apenas onde ainda não há configuração; não sobrescreve preferências.
insert into public.quote_settings(workspace_id) select id from public.workspaces on conflict(workspace_id) do nothing;

-- ETAPA 7: RLS e grants. Usuários comuns podem trabalhar em propostas do workspace,
-- catálogo/configuração são restritos a OWNER/ADMIN; eventos são somente leitura.
alter table public.quote_settings enable row level security;
alter table public.service_catalog enable row level security;
alter table public.quotes enable row level security;
alter table public.quote_items enable row level security;
alter table public.quote_approvals enable row level security;
alter table public.quote_events enable row level security;

drop policy if exists quote_settings_admin_all on public.quote_settings;
create policy quote_settings_admin_all on public.quote_settings for all to authenticated using(public.is_workspace_admin(workspace_id)) with check(public.is_workspace_admin(workspace_id));
drop policy if exists service_catalog_member_read on public.service_catalog;
create policy service_catalog_member_read on public.service_catalog for select to authenticated using(public.is_workspace_member(workspace_id));
drop policy if exists service_catalog_admin_write on public.service_catalog;
create policy service_catalog_admin_write on public.service_catalog for all to authenticated using(public.is_workspace_admin(workspace_id)) with check(public.is_workspace_admin(workspace_id));
drop policy if exists quotes_member_read on public.quotes;
create policy quotes_member_read on public.quotes for select to authenticated using(public.is_workspace_member(workspace_id));
drop policy if exists quotes_member_insert on public.quotes;
create policy quotes_member_insert on public.quotes for insert to authenticated with check(public.is_workspace_member(workspace_id) and created_by=auth.uid());
drop policy if exists quotes_member_update on public.quotes;
create policy quotes_member_update on public.quotes for update to authenticated using(public.is_workspace_member(workspace_id)) with check(public.is_workspace_member(workspace_id));
drop policy if exists quotes_admin_delete_draft on public.quotes;
create policy quotes_admin_delete_draft on public.quotes for delete to authenticated using(public.is_workspace_admin(workspace_id) or (public.is_workspace_member(workspace_id) and status='Rascunho' and created_by=auth.uid()));

drop policy if exists quote_items_member_read on public.quote_items;
create policy quote_items_member_read on public.quote_items for select to authenticated using(public.is_workspace_member(workspace_id));
drop policy if exists quote_items_member_insert on public.quote_items;
create policy quote_items_member_insert on public.quote_items for insert to authenticated with check(public.is_workspace_member(workspace_id) and exists(select 1 from public.quotes q where q.id=quote_items.quote_id and q.workspace_id=quote_items.workspace_id));
drop policy if exists quote_items_member_update on public.quote_items;
create policy quote_items_member_update on public.quote_items for update to authenticated using(public.is_workspace_admin(workspace_id) or (public.is_workspace_member(workspace_id) and exists(select 1 from public.quotes q where q.id=quote_items.quote_id and q.workspace_id=quote_items.workspace_id and q.status='Rascunho'))) with check(public.is_workspace_member(workspace_id));
drop policy if exists quote_items_member_delete on public.quote_items;
create policy quote_items_member_delete on public.quote_items for delete to authenticated using(public.is_workspace_member(workspace_id) and exists(select 1 from public.quotes q where q.id=quote_items.quote_id and q.workspace_id=quote_items.workspace_id and q.status='Rascunho'));

drop policy if exists quote_approvals_member_read on public.quote_approvals;
create policy quote_approvals_member_read on public.quote_approvals for select to authenticated using(public.is_workspace_member(workspace_id));
drop policy if exists quote_approvals_member_request on public.quote_approvals;
create policy quote_approvals_member_request on public.quote_approvals for insert to authenticated with check(public.is_workspace_member(workspace_id) and requested_by=auth.uid() and decision='pending');
drop policy if exists quote_approvals_admin_decide on public.quote_approvals;
create policy quote_approvals_admin_decide on public.quote_approvals for update to authenticated using(public.is_workspace_admin(workspace_id)) with check(public.is_workspace_admin(workspace_id));
drop policy if exists quote_events_member_read on public.quote_events;
create policy quote_events_member_read on public.quote_events for select to authenticated using(public.is_workspace_member(workspace_id));

revoke all on public.quote_settings,public.service_catalog,public.quotes,public.quote_items,public.quote_approvals,public.quote_events from anon,authenticated;
grant select,insert,update,delete on public.quote_settings to authenticated;
grant insert,update,delete on public.service_catalog to authenticated;
grant select(id,workspace_id,name,category,description,unit,reference_price,additional_days,recurring,periodicity,technical_evaluation_required,active,created_at,updated_at) on public.service_catalog to authenticated;
grant select(id,workspace_id,quote_number,lead_id,project_name,need_summary,client_snapshot,scope,owner,status,currency,total_amount,development_amount,recurring_amount,discount_amount,valid_until,sent_at,sent_by,approved_at,approved_by,approval_method,created_by,created_at,updated_at) on public.quotes to authenticated;
grant insert,update,delete on public.quotes to authenticated;
grant select(id,workspace_id,quote_id,catalog_id,name,description,quantity,unit_price,discount,subtotal,recurring,periodicity,technical_evaluation_required,created_at) on public.quote_items to authenticated;
grant insert,update,delete on public.quote_items to authenticated;
grant select,insert,update on public.quote_approvals to authenticated;
grant select on public.quote_events to authenticated;
grant select on public.service_catalog_public,public.service_catalog_admin,public.quote_items_public,public.quotes_public,public.quotes_admin to authenticated;
grant usage,select on sequence public.quote_number_seq to authenticated;

commit;

-- Limitações conhecidas: esta versão guarda a trilha de eventos e protege alterações
-- de status/preços com trigger, mas o fluxo de decisão de aprovação administrativa
-- deve ser acionado por UI/ação server-side autenticada. A sequence é global entre
-- workspaces (unicidade segura, sem lacunas garantidas). Execução e validação real
-- no projeto Supabase dependem de revisão e aplicação manual deste arquivo.

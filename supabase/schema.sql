-- PANDURU MUSIC database schema. Run once in Supabase SQL Editor.
create extension if not exists pgcrypto;

create table if not exists public.profiles(
 id uuid primary key references auth.users(id) on delete cascade,
 display_name text not null default 'Artist',
 bio text not null default '',
 location text not null default 'Kampala, Uganda',
 role text not null default 'artist' check(role in ('artist','admin')),
 created_at timestamptz not null default now()
);
create table if not exists public.songs(
 id uuid primary key default gen_random_uuid(),
 artist_id uuid not null references public.profiles(id) on delete cascade,
 title text not null,
 genre text not null default 'Other',
 description text not null default '',
 audio_path text not null,
 cover_path text,
 status text not null default 'pending' check(status in ('pending','approved','rejected')),
 created_at timestamptz not null default now()
);
create table if not exists public.song_events(
 id bigint generated always as identity primary key,
 song_id uuid not null references public.songs(id) on delete cascade,
 event_type text not null check(event_type in ('play','download')),
 created_at timestamptz not null default now()
);
create table if not exists public.favorites(
 user_id uuid not null references public.profiles(id) on delete cascade,
 song_id uuid not null references public.songs(id) on delete cascade,
 created_at timestamptz not null default now(),
 primary key(user_id,song_id)
);

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path=public
as $$
begin
 insert into public.profiles(id,display_name)
 values(new.id,coalesce(new.raw_user_meta_data->>'display_name',split_part(new.email,'@',1)))
 on conflict(id) do nothing;
 return new;
end; $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
for each row execute procedure public.handle_new_user();

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path=public
as $$ select exists(select 1 from public.profiles where id=auth.uid() and role='admin'); $$;

alter table public.profiles enable row level security;
alter table public.songs enable row level security;
alter table public.song_events enable row level security;
alter table public.favorites enable row level security;

drop policy if exists "profiles visible" on public.profiles;
create policy "profiles visible" on public.profiles for select using(id=auth.uid() or public.is_admin());
drop policy if exists "profile owner insert" on public.profiles;
create policy "profile owner insert" on public.profiles for insert with check(id=auth.uid() and role='artist');
drop policy if exists "profile owner update" on public.profiles;
create policy "profile owner update" on public.profiles for update using(id=auth.uid() or public.is_admin()) with check((id=auth.uid() and role='artist') or public.is_admin());

drop policy if exists "songs readable when approved or owner" on public.songs;
create policy "songs readable when approved or owner" on public.songs for select using(status='approved' or artist_id=auth.uid() or public.is_admin());
drop policy if exists "artists create pending songs" on public.songs;
create policy "artists create pending songs" on public.songs for insert with check(artist_id=auth.uid() and status='pending');
drop policy if exists "artists edit own pending or admin" on public.songs;
create policy "artists edit own pending or admin" on public.songs for update using((artist_id=auth.uid() and status='pending') or public.is_admin()) with check((artist_id=auth.uid() and status='pending') or public.is_admin());
drop policy if exists "admin delete songs" on public.songs;
create policy "admin delete songs" on public.songs for delete using(public.is_admin());

drop policy if exists "public event aggregate only" on public.song_events;
create policy "public event aggregate only" on public.song_events for select using(true);
-- Clients cannot insert events directly; RPC functions below validate published songs.
create or replace function public.record_song_play(p_song_id uuid)
returns void language plpgsql security definer set search_path=public
as $$ begin
 if exists(select 1 from public.songs where id=p_song_id and status='approved') then
  insert into public.song_events(song_id,event_type) values(p_song_id,'play');
 end if;
end; $$;
create or replace function public.record_song_download(p_song_id uuid)
returns void language plpgsql security definer set search_path=public
as $$ begin
 if exists(select 1 from public.songs where id=p_song_id and status='approved') then
  insert into public.song_events(song_id,event_type) values(p_song_id,'download');
 end if;
end; $$;
grant execute on function public.record_song_play(uuid) to anon,authenticated;
grant execute on function public.record_song_download(uuid) to anon,authenticated;

drop policy if exists "favorite owner read" on public.favorites;
create policy "favorite owner read" on public.favorites for select using(user_id=auth.uid());
drop policy if exists "favorite owner add" on public.favorites;
create policy "favorite owner add" on public.favorites for insert with check(user_id=auth.uid());
drop policy if exists "favorite owner remove" on public.favorites;
create policy "favorite owner remove" on public.favorites for delete using(user_id=auth.uid());

create or replace view public.songs_public as
select s.id,s.artist_id,s.title,s.genre,s.description,s.created_at,s.audio_path,s.cover_path,
 p.display_name as artist_name,
 coalesce((select count(*) from public.song_events e where e.song_id=s.id and e.event_type='play'),0)::bigint as plays,
 coalesce((select count(*) from public.song_events e where e.song_id=s.id and e.event_type='download'),0)::bigint as downloads,
from public.songs s join public.profiles p on p.id=s.artist_id
where s.status='approved';

create or replace view public.public_artist_profiles as
select p.id,p.display_name,p.bio,p.location
from public.profiles p
where exists(select 1 from public.songs s where s.artist_id=p.id and s.status='approved');

create or replace view public.artist_song_stats as
select s.artist_id,s.id as song_id,
 count(*) filter(where e.event_type='play')::bigint as plays,
 count(*) filter(where e.event_type='download')::bigint as downloads
from public.songs s left join public.song_events e on e.song_id=s.id
group by s.artist_id,s.id;

-- Storage buckets: public reads, authenticated users may upload only into their own UUID folder.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values
('music','music',true,52428800,array['audio/mpeg','audio/mp3','audio/wav','audio/x-wav','audio/mp4','audio/aac','audio/ogg']),
('covers','covers',true,5242880,array['image/jpeg','image/png','image/webp'])
on conflict(id) do update set public=excluded.public,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;

drop policy if exists "public read panduru assets" on storage.objects;
create policy "public read panduru assets" on storage.objects for select using(bucket_id in('music','covers'));
drop policy if exists "artists upload own panduru assets" on storage.objects;
create policy "artists upload own panduru assets" on storage.objects for insert to authenticated
with check(bucket_id in('music','covers') and (storage.foldername(name))[1]=auth.uid()::text);
drop policy if exists "artists update own panduru assets" on storage.objects;
create policy "artists update own panduru assets" on storage.objects for update to authenticated
using((storage.foldername(name))[1]=auth.uid()::text or public.is_admin())
with check((storage.foldername(name))[1]=auth.uid()::text or public.is_admin());
drop policy if exists "artists delete own panduru assets" on storage.objects;
create policy "artists delete own panduru assets" on storage.objects for delete to authenticated
using((storage.foldername(name))[1]=auth.uid()::text or public.is_admin());

-- Promote YOUR registered owner account to admin AFTER registration.
-- Replace the email, uncomment, and run this statement separately:
-- update public.profiles p set role='admin'
-- from auth.users u where p.id=u.id and u.email='YOUR-OWNER-EMAIL@example.com';

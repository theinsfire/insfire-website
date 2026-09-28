-- Insfire Studio — Supabase Storage for CMS image uploads
-- Run once in Supabase → SQL Editor. Safe to re-run.

-- 1. Public bucket: anyone can VIEW files by URL (needed for the public site).
--    Images only, 10 MB cap (matches the CMS check).
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('media', 'media', true, 10485760, array['image/jpeg','image/png','image/webp','image/gif','image/svg+xml','image/avif','image/x-icon','image/vnd.microsoft.icon'])
on conflict (id) do update set public = true, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

-- 2. Only the signed-in admin can upload, replace, delete or list files.
--    Public URLs (/storage/v1/object/public/media/...) need no policy.
drop policy if exists "insfire media admin select" on storage.objects;
drop policy if exists "insfire media admin insert" on storage.objects;
drop policy if exists "insfire media admin update" on storage.objects;
drop policy if exists "insfire media admin delete" on storage.objects;

create policy "insfire media admin select" on storage.objects for select to authenticated
  using (bucket_id = 'media' and lower(auth.jwt() ->> 'email') = 'theinsfire@gmail.com');

create policy "insfire media admin insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'media' and lower(auth.jwt() ->> 'email') = 'theinsfire@gmail.com');

create policy "insfire media admin update" on storage.objects for update to authenticated
  using (bucket_id = 'media' and lower(auth.jwt() ->> 'email') = 'theinsfire@gmail.com')
  with check (bucket_id = 'media' and lower(auth.jwt() ->> 'email') = 'theinsfire@gmail.com');

create policy "insfire media admin delete" on storage.objects for delete to authenticated
  using (bucket_id = 'media' and lower(auth.jwt() ->> 'email') = 'theinsfire@gmail.com');

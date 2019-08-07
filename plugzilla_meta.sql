set echo on
drop table plugzilla_meta purge;
create table plugzilla_meta 
 ( relationship  varchar2(30),
   child    varchar2(128),
   parent   varchar2(128),
   constraint plugzilla_meta_chk check ( relationship in ('SEED_FROM_PDB','CLONE_FROM_SEED','PENDING_CLONE') )
 );
set echo off
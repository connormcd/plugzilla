whenever sqlerror exit
begin
  if user != 'SYS' then
    raise_application_error(-20000,'You should be SYS for this');
  end if;
end;
/

begin
  if sys_context('USERENV','CON_NAME') != 'CDB$ROOT' then
    raise_application_error(-20000,'You should be in CDB$ROOT for this');
  end if;
end;
/
whenever sqlerror continue

prompt
prompt Warning: This install will drop the PLUGZILLA_META if it already exists. 
prompt
prompt If you are just re-installing the packages, this could be a bad idea because you
prompt lose the state of your current pluggables
prompt
prompt Press Ctrl-C now if you want to abort
pause


@@plugzilla_meta.sql
@@plugzilla_pb.sql
@@plugzilla_ps.sql
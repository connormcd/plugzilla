create or replace
package body plugzilla is
  g_seed_prefix    constant varchar2(10) := 'SEED_';
  g_pend_prefix    constant varchar2(10) := 'PEND_';
  g_reserve_copies constant int := 3;
 
  g_seed_from_pdb   constant varchar2(30) := 'SEED_FROM_PDB';
  g_clone_from_seed constant varchar2(30) := 'CLONE_FROM_SEED';
  g_pending_clone   constant varchar2(30) := 'PENDING_CLONE';

procedure msg(m varchar2) is
begin
  dbms_output.put_line(m);
end;

procedure release_usage(p_from_die boolean default false);

procedure die(m varchar2) is
begin
  release_usage(p_from_die=>true);
  raise_application_error(-20100,m);
end;

procedure ddl(m varchar2) is
begin
  msg(m);
  execute immediate m;
end;

procedure serialise_usage is
  l_lock_handle     varchar2(128);
  l_lock_status     number;
begin
  ddl('alter session set container = cdb$root');
  dbms_lock.allocate_unique (
     'PLUGZILLA',
     l_lock_handle);

  l_lock_status := dbms_lock.request(
    lockhandle=>l_lock_handle,
    timeout=>0,
    release_on_commit=>false);

  if l_lock_status not in (0,4) then
    die('Could not serialize access to PLUGZILLA. One person at a time only, status came back as '||l_lock_status);
  end if;

end;

procedure release_usage(p_from_die boolean default false) is
  l_lock_handle     varchar2(128);
  l_lock_status     number;
begin
  ddl('alter session set container = cdb$root');
  dbms_lock.allocate_unique (
     'PLUGZILLA',
     l_lock_handle);

  l_lock_status := dbms_lock.release(
    lockhandle=>l_lock_handle);

  if not p_from_die then
    if l_lock_status != 0 then
      die('Abnormal error trying to release lock, status came back as '||l_lock_status);
    end if;
  end if;
end;

procedure cheeky_hacker(p_pdb varchar2) is
begin
  if p_pdb like '%$%' then
    die('Why on earth are you tinkering with pluggable names that contain a $????');
  end if;
end;

function pdb_exists(p_pdb varchar2) return boolean is
  l_exists int;
begin
  cheeky_hacker(p_pdb);

  select count(*) into l_exists
  from   v$pdbs
  where  name = p_pdb;
  return l_exists > 0;
end;

function pdb_mode(p_pdb varchar2) return varchar2 is
  l_mode   varchar2(20);
begin
  cheeky_hacker(p_pdb);
  select open_mode into l_mode
  from   v$pdbs
  where  name = p_pdb;
  return l_mode;
exception
  when no_data_found then 
     die('Pluggable '||p_pdb||' could not be found');
end;
  
function clean_seed(p_seed varchar2) return varchar2 is
  l_seed   varchar2(128);
begin
  cheeky_hacker(p_seed);
  l_seed   := 
     ltrim(rtrim(
       case 
         when instr(upper(p_seed),upper(g_seed_prefix)) = 1 then upper(substr(p_seed,length(g_seed_prefix)+1))
         else upper(p_seed)
       end
       ));
  if l_seed is null then
    die('Seed must not be null. Did you miss something after the prefix?');
  end if;
  if regexp_replace(l_seed,'[[:alnum:]]+') is not null then
      die('Seed must be simple alphanumerics');
  end if;

  return upper(g_seed_prefix)||l_seed;
end;

procedure new_seed_from_existing(p_source varchar2, p_seed varchar2,p_read_write_after_create boolean default false) is
  l_exists int;
  l_mode   varchar2(20);
  l_source varchar2(128) := upper(ltrim(rtrim(p_source)));
  l_seed   varchar2(128) := clean_seed(p_seed);
begin
  serialise_usage;

  --
  -- seed must not exist
  --
  if pdb_exists(l_seed) then
    die('Pluggable '||l_seed||' already exists');
  end if;

  --
  -- source must exist, and must not be already involved in plugzilla in an inappropriate way
  --
  l_mode := pdb_mode(l_source);
  
  select count(*)
  into   l_exists
  from   plugzilla_meta
  where  child = l_source;
  if l_exists > 0 then
    die('Pluggable '||l_source||' is listed as a child in plugzilla. That sounds like a mess');
  end if;
  
  msg('seed='||l_seed);
  msg('src='||l_source||',mode='||l_mode);
  
  if l_mode = 'MOUNTED' then
    ddl('alter pluggable database '||l_source||' open restricted');
    ddl('alter pluggable database '||l_source||' close immediate');
    ddl('alter pluggable database '||l_source||' open read only');
  elsif l_mode = 'READ WRITE' then
    ddl('alter pluggable database '||l_source||' close immediate');
    ddl('alter pluggable database '||l_source||' open read only');
  end if;

  ddl('create pluggable database '||l_seed||' from '||l_source||' '||
                    'file_name_convert=('''||l_source||''','''||l_seed||''')');

  if p_read_write_after_create then
    ddl('alter pluggable database '||l_seed||' open');
  else
    ddl('alter pluggable database '||l_seed||' open restricted');
    ddl('alter pluggable database '||l_seed||' close immediate');
    ddl('alter pluggable database '||l_seed||' open read only');
  end if;
  delete from plugzilla_meta
  where  relationship = g_seed_from_pdb
  and    child        = l_seed;

  --
  -- reset the state of the source
  --
  if l_mode = 'MOUNTED' then
    ddl('alter pluggable database '||l_source||' close immediate');
  elsif l_mode = 'READ WRITE' then
    ddl('alter pluggable database '||l_source||' close immediate');
    ddl('alter pluggable database '||l_source||' open');
  end if;

  
  insert into plugzilla_meta (relationship,child,parent)
  values (g_seed_from_pdb,l_seed,l_source);
  commit;
  release_usage;
end;

procedure clone_from_seed(p_seed varchar2, p_clone varchar2 default 'AUTO', p_wait_for_preclone boolean default false) is 
  l_seed   varchar2(128) := clean_seed(p_seed);
  l_clone varchar2(128) := upper(ltrim(rtrim(p_clone)));
  l_mode   varchar2(20);
  l_pend_pdb varchar2(128);
begin 
  serialise_usage;
  --
  -- seed must exist
  --
  if not  pdb_exists(l_seed) then
    die('Pluggable '||l_seed||'does not exist');
  end if;

  --
  -- clone must not exist
  --
  if pdb_exists(l_clone) then
    die('Pluggable '||l_clone||' already exists');
  end if;

  --
  -- then aim here is a pending clone is always there ready, otherwise
  -- we might cop a wait for preclone
  --
  for i in 1 .. 2 
  loop  
    begin
      select child
      into   l_pend_pdb
      from 
      ( select child
        from   plugzilla_meta
        where  parent = l_seed
        and    relationship = g_pending_clone
        order  by child
      )
      where rownum = 1;
      exit;
    exception
      when no_data_found then
         if p_wait_for_preclone then 
            if i = 1 then
              msg('No available pending pdbs, waiting for preclone to set one up for us');
              plugzilla.preclone(l_seed);
            else
              die('Waited for preclone to run, and we still had no pending clones. This should never happen');
            end if;
         else 
            die('No available pending pdbs found. Perhaps run preclone');
         end if;
    end;         
  end loop;
  msg('Found pending pdb '||l_pend_pdb||' to use');
  if l_clone = 'AUTO' then
    l_clone := substr(l_pend_pdb,length(g_pend_prefix)+1);
    --
    -- one extra check for AUTO
    --
    if pdb_exists(l_clone) then
      die('Pluggable '||l_clone||' already exists');
    end if;
  end if;
  
  l_mode := pdb_mode(l_pend_pdb);

  if l_mode != 'MOUNTED' then
    ddl('alter pluggable database '||l_pend_pdb||' close immediate');
  end if;

  ddl('alter pluggable database '||l_pend_pdb||' open restricted');
  ddl('alter session set container = '||l_pend_pdb);
  ddl('alter pluggable database '||l_pend_pdb||' rename global_name to '||l_clone);
  ddl('alter pluggable database '||l_clone||' close immediate');
  ddl('alter pluggable database '||l_clone||' open');

  ddl('alter session set container = cdb$root');
  
  update plugzilla_meta
  set    relationship = g_clone_from_seed,
         child = l_clone
  where  child = l_pend_pdb
  and    parent = l_seed
  and    relationship = g_pending_clone;
  commit;
  release_usage;
end;

procedure drop_clone(p_clone varchar2, p_sync boolean default false) is 
  l_exists int;
  l_clone varchar2(128) := upper(ltrim(rtrim(p_clone)));
  l_children varchar2(1000);
  l_mode   varchar2(20);
begin
  serialise_usage;
  --
  -- clone must exist
  --
  l_mode := pdb_mode(l_clone);

  --
  -- 2 possible clone types here
  -- 
  -- first is a pending clone, easiest to handle
  --
  select count(*)
  into   l_exists
  from   plugzilla_meta
  where  relationship in (g_pending_clone,g_clone_from_seed)
  and    child = l_clone;
  
  if l_exists > 0 
  then
    msg('Dropping clone '||l_clone);
    if l_mode != 'MOUNTED' then
      ddl('alter pluggable database '||l_clone||' close immediate');
    end if;
    ddl('drop pluggable database '||l_clone||' including datafiles');
    delete
    from   plugzilla_meta
    where  relationship in (g_pending_clone,g_clone_from_seed)
    and    child = l_clone;
    commit;  
  else
    die('Pluggable '||l_clone||' not found a clone or pending clone in Plugzilla');
  end if;

  release_usage;
end;

procedure drop_seed(p_seed varchar2, p_sync boolean default false) is
  l_seed   varchar2(128) := clean_seed(p_seed);
  l_children varchar2(1000);
begin
  serialise_usage;
  if not pdb_exists(l_seed) then
    die('Pluggable '||l_seed||' does not exist');
  end if;
  
  select listagg(child,',') within group ( order by child ) 
  into   l_children
  from   plugzilla_meta
  where  relationship in (g_clone_from_seed,g_pending_clone)
  and    parent = l_seed;
  
  if l_children is not null then
    die('Seed '||l_seed||' has the following children which must be dropped first with DROP_CLONE: '||l_children);
  end if;

  ddl('alter pluggable database '||l_seed||' close immediate');
  ddl('drop pluggable database '||l_seed||' including datafiles');

  delete
  from   plugzilla_meta
  where  relationship = g_seed_from_pdb
  and    child = l_seed;
  commit;
  release_usage;
end;

procedure drop_all_clones(p_seed varchar2, p_sync boolean default false) is
  l_seed   varchar2(128) := clean_seed(p_seed);
begin
  for i in ( select child
             from   plugzilla_meta
             where  parent = l_seed
             and    relationship in (g_clone_from_seed,g_pending_clone) )
  loop
    drop_clone(i.child,p_sync);
  end loop;
end;


procedure preclone(p_seed varchar2 default null) is
  l_pending int;
  l_pend_hwm int;
  l_mode    varchar2(20);
  l_pend_pdb varchar2(128);
begin
  serialise_usage;
  if p_seed is not null then
    cheeky_hacker(p_seed);
  end if;

  for i in ( select child
             from   plugzilla_meta
             where  relationship = g_seed_from_pdb
             and    child = nvl(p_seed,child)
           )
  loop
    msg('Processing seed: '||i.child);
    select count(*), nvl(to_number(max(substr(child,-3))),0)
    into   l_pending, l_pend_hwm
    from   plugzilla_meta
    where  relationship = g_pending_clone
    and    parent = i.child;
    msg('- pending clones: '||l_pending);
    
    if l_pending < g_reserve_copies then
      msg('- building '||(g_reserve_copies-l_pending)||' pre-clones');
      l_mode := pdb_mode(i.child);

      if l_mode = 'MOUNTED' then
        ddl('alter pluggable database '||i.child||' open restricted');
        ddl('alter pluggable database '||i.child||' close immediate');
        ddl('alter pluggable database '||i.child||' open read only');
      elsif l_mode = 'READ WRITE' then
        ddl('alter pluggable database '||i.child||' close immediate');
        ddl('alter pluggable database '||i.child||' open read only');
      end if;

      for j in l_pend_hwm+1 .. ( l_pend_hwm + g_reserve_copies - l_pending )
      loop
        l_pend_pdb := g_pend_prefix||substr(i.child,length(g_seed_prefix)+1)||to_char(j,'fm000');
        
        ddl('create pluggable database '||l_pend_pdb||' from '||i.child||' '||
                          'file_name_convert=('''||i.child||''','''||l_pend_pdb||''')');

        insert into plugzilla_meta (relationship,child,parent)
        values (g_pending_clone,l_pend_pdb,i.child);
        commit;

      end loop;

      --
      -- reset the state of the seed
      --
      if l_mode = 'MOUNTED' then
        ddl('alter pluggable database '||i.child||' close immediate');
      elsif l_mode = 'READ WRITE' then
        ddl('alter pluggable database '||i.child||' close immediate');
        ddl('alter pluggable database '||i.child||' open');
      end if;

    end if;
  end loop;
  release_usage;
end;


end;
/
sho err

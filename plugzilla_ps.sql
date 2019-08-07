create or replace
package plugzilla is

  procedure new_seed_from_existing(p_source varchar2, p_seed varchar2,p_read_write_after_create boolean default false);
  procedure clone_from_seed(p_seed varchar2, p_clone varchar2 default 'AUTO', p_wait_for_preclone boolean default false);
  procedure drop_clone(p_clone varchar2, p_sync boolean default false);
  procedure drop_seed(p_seed varchar2, p_sync boolean default false);
  procedure drop_all_clones(p_seed varchar2, p_sync boolean default false);
  procedure preclone(p_seed varchar2 default null);
  
end;
/
sho err

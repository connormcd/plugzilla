# plugzilla

Cloning a pluggable database takes time, and for environments where you'd like to use clones as part of unit testing, or other elements of Agile development, it would be nice to be able to bring a clone into operation in the smallest time possible. One mechanism for that is sparse storage clones aka snapshot copy, but depending on your version and your storage infrastructure, you might hit some limitations. So this package allows you clone pluggable databases extremely quickly by having pluggable database pre-cloned in advance.

## Example

Lets say you have a dev pluggable database called PDB1.  You want to let developers take clones of this as quickly and as often as they like and at various stages in its lifecycle. Here how we might do it with plugzilla.

1) On Sunday June 1st, we've just built (say) version 3.1 of our app into PDB1. I want a frozen copy of PDB1 that can be used as a seed for developers to clone.  So I'll do:

```console
SQL> set serverout on
SQL> exec plugzilla.new_seed_from_existing(p_source=>'PDB1',p_seed=>'PDB31');
alter session set container = cdb$root
seed=SEED_PDB31
src=PDB1,mode=READ WRITE
alter pluggable database PDB1 close immediate
alter pluggable database PDB1 open read only
create pluggable database SEED_PDB31 from PDB1 file_name_convert=('PDB1','SEED_PDB31')
alter pluggable database SEED_PDB31 open restricted
alter pluggable database SEED_PDB31 close immediate
alter pluggable database SEED_PDB31 open read only
alter pluggable database PDB1 close immediate
alter pluggable database PDB1 open
alter session set container = cdb$root

PL/SQL procedure successfully completed.
```

This will create a pluggable database called SEED_PDB31 (all the seeds will have the prefix "SEED_", but see the package constants if you want to change this)

2) On Wednesday June 4th, we've just built (say) version 3.2 of our app into PDB1. I again want a frozen copy of PDB1 that can be used as a seed for developers to clone.  So I'll do:

```console
SQL> exec plugzilla.new_seed_from_existing(p_source=>'PDB1',p_seed=>'PDB32');
alter session set container = cdb$root
seed=SEED_PDB32
src=PDB1,mode=READ WRITE
alter pluggable database PDB1 close immediate
alter pluggable database PDB1 open read only
create pluggable database SEED_PDB32 from PDB1 file_name_convert=('PDB1','SEED_PDB32')
alter pluggable database SEED_PDB32 open restricted
alter pluggable database SEED_PDB32 close immediate
alter pluggable database SEED_PDB32 open read only
alter pluggable database PDB1 close immediate
alter pluggable database PDB1 open
alter session set container = cdb$root

PL/SQL procedure successfully completed.
```

So now we have two seed copies of PDB1 at different points in time. These are the pluggables that are the base for any developer to clone from.  

3) We now call plugzilla.preclone (although more likely is that you would have this as a scheduler job).  This will look for any seeds (we have 2 from above) and pre-create 'n' pluggable copies of those databases where 'n is defined by the package constant 'g_reserve_copies'

```console
SQL> exec plugzilla.preclone
alter session set container = cdb$root
Processing seed: SEED_PDB31
- pending clones: 0
- building 3 pre-clones
create pluggable database PEND_PDB3100001 from SEED_PDB31 file_name_convert=('SEED_PDB31','PEND_PDB3100001')
create pluggable database PEND_PDB3100002 from SEED_PDB31 file_name_convert=('SEED_PDB31','PEND_PDB3100002')
create pluggable database PEND_PDB3100003 from SEED_PDB31 file_name_convert=('SEED_PDB31','PEND_PDB3100003')
Processing seed: SEED_PDB32
- pending clones: 0
- building 3 pre-clones
create pluggable database PEND_PDB3200001 from SEED_PDB32 file_name_convert=('SEED_PDB32','PEND_PDB3200001')
create pluggable database PEND_PDB3200002 from SEED_PDB32 file_name_convert=('SEED_PDB32','PEND_PDB3200002')
create pluggable database PEND_PDB3200003 from SEED_PDB32 file_name_convert=('SEED_PDB32','PEND_PDB3200003')
alter session set container = cdb$root

PL/SQL procedure successfully completed.
```

These "pending" clones are fully operational pluggables that are yet to be claimed by a developer. They are pre-created so that when a developer wants a clone, they can do it very quickly.

4) A developer wants a sandbox pluggable of the application as of version 3.1. They simply ask for one

```console
SQL> exec plugzilla.clone_from_seed('PDB31')
alter session set container = cdb$root
Found pending pdb PEND_PDB3100001 to use
alter pluggable database PEND_PDB3100001 open restricted
alter session set container = PEND_PDB3100001
alter pluggable database PEND_PDB3100001 rename global_name to PDB3100001
alter pluggable database PDB3100001 close immediate
alter pluggable database PDB3100001 open
alter session set container = cdb$root

PL/SQL procedure successfully completed.
```

The first available pending pluggable database is picked from the list and renamed to PDB31001. This is an automatically generated name, but developers can choose their own. Because this is just a rename, the developer will have their pluggable *irrespective* of size available to them within 5-10 seconds.

If we want a second sandbox clone, this time with a custom name, I'll simply run the routine again

```console
SQL> exec plugzilla.clone_from_seed('PDB31','MYDB')
alter session set container = cdb$root
Found pending pdb PEND_PDB3100002 to use
alter pluggable database PEND_PDB3100002 open restricted
alter session set container = PEND_PDB3100002
alter pluggable database PEND_PDB3100002 rename global_name to MYDB
alter pluggable database MYDB close immediate
alter pluggable database MYDB open
alter session set container = cdb$root

PL/SQL procedure successfully completed.
```

5) When the developer is done with their clone, they drop it.


```console
SQL> exec plugzilla.drop_clone('MYDB')
alter session set container = cdb$root
Dropping clone MYDB
alter pluggable database MYDB close immediate
drop pluggable database MYDB including datafiles
alter session set container = cdb$root

PL/SQL procedure successfully completed.
```

Note that this does not "return" the pluggable to the pool of available pluggables, because that database could contain changes which means it will have diverged from its initial seed. It is completely dropped and the space freed up. It is 'preclone' alone that keeps a preallocation of pluggables available. Because the numeric suffix continues to rise, there is a cap of 99999 pluggables that could be created. If your application is not deployed by then, you've got bigger issues to worry about :-)

At any time, the table contains the state of plugzilla. After the above operations, it would look like this:

```console
SQL> select * from plugzilla_meta;

RELATIONSHIP                   CHILD                PARENT
------------------------------ -------------------- -----------------
SEED_FROM_PDB                  SEED_PDB31           PDB1                 => we took a seed PDB31 from PDB1
SEED_FROM_PDB                  SEED_PDB32           PDB1                 => we took a seed PDB32 from PDB1
PENDING_CLONE                  PEND_PDB3100003      SEED_PDB31           => preclone built these
PENDING_CLONE                  PEND_PDB3200001      SEED_PDB32
PENDING_CLONE                  PEND_PDB3200002      SEED_PDB32
PENDING_CLONE                  PEND_PDB3200003      SEED_PDB32
CLONE_FROM_SEED                PDB3100001           SEED_PDB31           => we took a preclone and converted it to a clone
```

Notes

1) There are many many options in terms of cloning for pluggable databases. This package goes with the Keep-It-Simple policy. It is going to clone pluggables by

- making the source read only
- cloning the datafiles replacing existing pluggable name with a new one

2) As you'd expect, this software comes WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.

3) Don't forget - you're messing with pluggable databases here. Don't be THAT person that drops all your data!

4) Notice when a pending pluggable becomes owned by a developer, the files are not being moved or renamed. This is done to keep the operation nice and snappy.

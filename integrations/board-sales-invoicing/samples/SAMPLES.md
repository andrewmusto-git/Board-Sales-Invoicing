# Sample Data — Board Sales Invoicing (IBM i / AS400)

Place representative sample query outputs here before running the dry-run tester.

## Required files

### `accounts_sample.csv`
A CSV export of the Account SQL Query result (at least 5 rows). Must contain these columns:
```
User_ID, User_Name, User_EIN, System_ID, Description
```
Example row:
```
JDOE,John Doe,12345678,SALES,*UPDATE* SALES ORDER ENTRY
```

### `groups_sample.csv`
A CSV export of the Access Group SQL Query result (at least 5 rows). Must contain this column:
```
SUBMENU
```
Example row:
```
*UPDATE* SALES ORDER ENTRY
CUSTOMER INQUIRY
```

### `roles_sample.csv`
A CSV export of the System_ID Group SQL Query result (at least 5 rows). Must contain this column:
```
EM_ROLE
```
Example row:
```
SALES
AR
ADMIN
```

## How to generate samples

Run these queries directly against `CORP986.westrock.com` and export to CSV:

**Account Query (accounts_sample.csv):**
```sql
select TRIM(emp.usrid) as User_ID, TRIM(emp.em_user_name) as User_Name,
       TRIM(emp.empid) as User_EIN, TRIM(EMP.ROLE) as System_ID,
       case
         when sub.mnutext = 'ALL SUBMENUS' and sec.authority = 'Y' and sub.updates = 'Y'
           Then '*UPDATE* ' || TRIM(mnu.MNUTEXT)
         when sub.mnutext = 'ALL SUBMENUS' and (sec.authority <> 'Y' or sub.updates <> 'Y')
           Then TRIM(mnu.MNUTEXT) else TRIM(sub.MNUTEXT)
       end Description
FROM pdmstrdblb.asas sec, pdmstrdblb.apmenus mnu, pdmstrdblb.apsubmn sub, pdmstrdblb.asem emp
where sec.MNUPROGRAM = mnu.MNUPGM
  and sec.MNUPROGRAM = sub.MNUPGM
  and sec.SELECTION = sub.SUBMNU
  and sec.USRID = emp.USRID
  and emp.em_status = 'A'
Order by User_id, User_EIN, System_ID, Description
FETCH FIRST 100 ROWS ONLY
```

**Group Query (groups_sample.csv):**
```sql
SELECT distinct
  case
    when sub.mnutext = 'ALL SUBMENUS' and sec.authority = 'Y' and sub.updates = 'Y'
      Then '*UPDATE* ' || TRIM(mnu.MNUTEXT)
    when sub.mnutext = 'ALL SUBMENUS' and (sec.authority <> 'Y' or sub.updates <> 'Y')
      Then TRIM(mnu.MNUTEXT) else TRIM(sub.MNUTEXT)
  end SUBMENU
FROM pdmstrdblb.asas sec, pdmstrdblb.apmenus mnu, pdmstrdblb.apsubmn sub, pdmstrdblb.asem emp
where sec.MNUPROGRAM = mnu.MNUPGM
  and sec.MNUPROGRAM = sub.MNUPGM
  and sec.SELECTION = sub.SUBMNU
  and sec.USRID = emp.USRID
  and emp.em_status = 'A'
```

**Role Query (roles_sample.csv):**
```sql
select distinct TRIM(asem.EM_ROLE) as EM_ROLE from PDMSTRDBLB.asem AS asem
```


with Ada.Containers.Doubly_Linked_Lists;
with Ada.Containers.Indefinite_Doubly_Linked_Lists;
with Ada.Containers.Indefinite_Hashed_Sets;
with Ada.Finalization;

package GNATCOLL.SQL_Impl is

   type Cst_String_Access is access constant String;
   --  Various aspects of a database description (table names, field names,...)
   --  are represented as string. To limit the number of memory allocation and
   --  deallocation (and therefore increase speed), this package uses such
   --  strings as Cst_String_Access. These strings are never deallocation, and
   --  should therefore be pointed to "aliased constant String" in your
   --  code, as in:
   --       Name : aliased constant String := "mysubquery";
   --       Q : SQL_Query := SQL_Select
   --          (Fields => ...,
   --           From   => Subquery (SQL_Select (...),
   --                               Name => Name'Access));

   Null_String : aliased constant String := "NULL";

   -------------------------------------
   -- General declarations for tables --
   -------------------------------------
   --  The following declarations are needed to be able to declare the
   --  following generic packages. They are repeated in GNATCOLL.SQL for ease
   --  of use.

   type Table_Names is record
      Name     : Cst_String_Access;
      Instance : Cst_String_Access;
   end record;
   No_Names : constant Table_Names := (null, null);
   --  Describes a table (by its name), and the name of its instance. This is
   --  used to find all tables involved in a query, for the auto-completion. We
   --  do not store instances of SQL_Table'Class directly, since that would
   --  involve several things:
   --     - extra Initialize/Adjust/Finalize calls
   --     - Named_Field_Internal would need to embed a pointer to a table, as
   --       opposed to just its names, and therefore must be a controlled type.
   --       This makes the automatic package more complex, and makes the field
   --       type controlled, which is also a lot more costly.

   function Hash (Self : Table_Names) return Ada.Containers.Hash_Type;
   package Table_Sets is new Ada.Containers.Indefinite_Hashed_Sets
     (Table_Names, Hash, "=", "=");

   type SQL_Table_Or_List is abstract tagged private;
   --  Either a single table or a group of tables

   procedure Append_Tables
     (Self : SQL_Table_Or_List; To : in out Table_Sets.Set) is null;
   --  Append all the tables referenced in Self to To

   function To_String (Self : SQL_Table_Or_List) return String is abstract;
   --  Convert the table to a string

   type SQL_Single_Table (Instance : GNATCOLL.SQL_Impl.Cst_String_Access)
      is abstract new SQL_Table_Or_List with private;
   --  Any type of table, or result of join between several tables. Such a
   --  table can have fields

   -------------------------------------
   -- General declarations for fields --
   -------------------------------------

   type SQL_Assignment is private;

   type SQL_Field_Or_List is abstract tagged null record;
   --  Either a single field or a list of fields

   function To_String
     (Self : SQL_Field_Or_List; Long : Boolean := True) return String
      is abstract;
   --  Convert the field to a string. If Long is true, a fully qualified
   --  name is used (table.name), otherwise just the field name is used

   type SQL_Field_List is new SQL_Field_Or_List with private;
   Empty_Field_List : constant SQL_Field_List;
   --  A list of fields, as used in a SELECT query ("field1, field2");

   overriding function To_String
     (Self : SQL_Field_List; Long : Boolean := True) return String;
   --  See inherited doc

   type SQL_Field (Table, Instance, Name : Cst_String_Access)
      is abstract new SQL_Field_Or_List with null record;
   --  A field that comes directly from the database. It can be within a
   --  specific table instance, but we still need to know the name of the table
   --  itself for the autocompletion.
   --  (Table,Instance) might be null if the field is a constant

   overriding function To_String
     (Self : SQL_Field; Long : Boolean := True)  return String;
   --  See inherited doc

   procedure Append_Tables (Self : SQL_Field; To : in out Table_Sets.Set);
   --  Append the table(s) referenced by Self to To.
   --  This is used for auto-completion later on

   procedure Append_If_Not_Aggregate
     (Self         : SQL_Field;
      To           : in out SQL_Field_List'Class;
      Is_Aggregate : in out Boolean);
   --  Append all fields referenced by Self if Self is not the result of an
   --  aggregate function. This is used for autocompletion of "group by".
   --  Is_Aggregate is set to True if Self is an aggregate, untouched otherwise

   function "&" (Left, Right : SQL_Field'Class) return SQL_Field_List;
   function "&" (Left, Right : SQL_Field_List) return SQL_Field_List;
   function "&"
     (Left : SQL_Field_List; Right : SQL_Field'Class) return SQL_Field_List;
   function "&"
     (Left : SQL_Field'Class; Right : SQL_Field_List) return SQL_Field_List;
   --  Create lists of fields

   function "+" (Left : SQL_Field'Class) return SQL_Field_List;
   --  Create a list with a single field

   package Field_List is new Ada.Containers.Indefinite_Doubly_Linked_Lists
     (SQL_Field'Class);

   function First (List : SQL_Field_List) return Field_List.Cursor;
   --  Return the first field contained in the list

   --------------------
   -- Field pointers --
   --------------------
   --  A smart pointer that frees memory whenever the field is no longer needed

   type SQL_Field_Pointer is private;
   No_Field_Pointer : constant SQL_Field_Pointer;
   --  A smart pointer

   function "+" (Field : SQL_Field'Class) return SQL_Field_Pointer;
   --  Create a new pointer. Memory will be deallocated automatically

   procedure Append
     (List : in out SQL_Field_List'Class; Field : SQL_Field_Pointer);
   --  Append a new field to the list

   function To_String (Self : SQL_Field_Pointer; Long : Boolean) return String;
   procedure Append_Tables
     (Self : SQL_Field_Pointer; To : in out Table_Sets.Set);
   procedure Append_If_Not_Aggregate
     (Self         : SQL_Field_Pointer;
      To           : in out SQL_Field_List'Class;
      Is_Aggregate : in out Boolean);
   --  See doc for SQL_Field

   ----------------
   -- Field data --
   ----------------
   --  There are two kinds of fields: one is simple fields coming straight from
   --  the database ("table.field"), the other are fields computed through this
   --  API ("field1 || field2", Expression ("field"), "field as name"). The
   --  latter need to allocate memory to store their contents, and are stored
   --  in a refcounted type internally, so that we can properly manage memory.

   type SQL_Field_Internal is abstract tagged record
      Refcount : Natural := 1;
   end record;
   type SQL_Field_Internal_Access is access all SQL_Field_Internal'Class;
   --  Data that can be stored in a field

   procedure Free (Data : in out SQL_Field_Internal) is null;
   --  Free memory associated with Data

   function To_String
     (Self : SQL_Field_Internal; Long : Boolean) return String is abstract;
   procedure Append_Tables
     (Self : SQL_Field_Internal; To : in out Table_Sets.Set) is null;
   procedure Append_If_Not_Aggregate
     (Self         : access SQL_Field_Internal;
      To           : in out SQL_Field_List'Class;
      Is_Aggregate : in out Boolean) is null;
   --  The three subprograms are equivalent to the ones for SQL_Field. When a
   --  field contains some data, it will simply delegate the calls to the above
   --  subprograms.

   type Field_Data is new Ada.Finalization.Controlled with record
      Data : SQL_Field_Internal_Access;
   end record;
   --  The type that is actually stored in a field, and provides the
   --  refcounting for Data.

   overriding procedure Adjust   (Self : in out Field_Data);
   overriding procedure Finalize (Self : in out Field_Data);
   --  Refcounted internal data for some types of fields

   generic
      type Base_Field is abstract new SQL_Field with private;
   package Data_Fields is
      type Field is new Base_Field with record
         Data : Field_Data;
      end record;

      overriding function To_String
        (Self : Field; Long : Boolean := True)  return String;
      overriding procedure Append_Tables
        (Self : Field; To : in out Table_Sets.Set);
      overriding procedure Append_If_Not_Aggregate
        (Self         : Field;
         To           : in out SQL_Field_List'Class;
         Is_Aggregate : in out Boolean);
   end Data_Fields;
   --  Mixin inheritand for a field, to add specific user data to them. This
   --  user data is refcounted. Field just acts as a proxy for Data, and
   --  delegates all its operations to Data.

   ----------------------------------------
   -- General declarations for criterias --
   ----------------------------------------

   type SQL_Criteria is private;
   No_Criteria : constant SQL_Criteria;

   function To_String
     (Self : SQL_Criteria; Long : Boolean := True) return String;
   procedure Append_Tables (Self : SQL_Criteria; To : in out Table_Sets.Set);
   procedure Append_If_Not_Aggregate
     (Self         : SQL_Criteria;
      To           : in out SQL_Field_List'Class;
      Is_Aggregate : in out Boolean);
   --  The usual semantics for these subprograms (see SQL_Field)

   type SQL_Criteria_Data is abstract tagged private;
   type SQL_Criteria_Data_Access is access all SQL_Criteria_Data'Class;
   --  The data contained in a criteria. You can create new versions of it if
   --  you need to create new types of criterias

   procedure Free (Self : in out SQL_Criteria_Data) is null;
   --  Free memory associated with Self

   function To_String
     (Self : SQL_Criteria_Data; Long : Boolean := True) return String
      is abstract;
   procedure Append_Tables
     (Self : SQL_Criteria_Data; To : in out Table_Sets.Set) is null;
   procedure Append_If_Not_Aggregate
     (Self         : SQL_Criteria_Data;
      To           : in out SQL_Field_List'Class;
      Is_Aggregate : in out Boolean) is null;
   --  See description of these subprograms for a SQL_Criteria

   procedure Set_Data
     (Self : in out SQL_Criteria; Data : not null access SQL_Criteria_Data);
   function Get_Data (Self : SQL_Criteria) return SQL_Criteria_Data_Access;
   --  Set the data associated with Self.
   --  This is only needed when you implement your own kinds of criteria, not
   --  when writing SQL queries.

   function Compare
     (Left, Right : SQL_Field'Class;
      Op          : Cst_String_Access;
      Suffix      : Cst_String_Access := null)
      return SQL_Criteria;
   --  Used to write comparison operations. This is a low-level implementation,
   --  which should only be used when writing your own criterias, not when
   --  writing queries.
   --  The operation is written as
   --     Left Op Right Suffix

   ------------------------------------------
   -- General declarations for assignments --
   ------------------------------------------

   No_Assignment : constant SQL_Assignment;

   function "&" (Left, Right : SQL_Assignment) return SQL_Assignment;
   --  Concat two assignments

   procedure Append_Tables (Self : SQL_Assignment; To : in out Table_Sets.Set);
   function To_String
     (Self : SQL_Assignment; With_Field : Boolean)  return String;
   --  The usual semantics for these subprograms (see fields)

   procedure To_List (Self : SQL_Assignment; List : out SQL_Field_List);
   --  Return the list of values in Self as a list of fields. This is used for
   --  statements likes "INSERT INTO ... SELECT list"

   procedure Get_Fields (Self : SQL_Assignment; List : out SQL_Field_List);
   --  Return the list of fields impacted by the assignments

   --------------
   -- Generics --
   --------------
   --  The following package can be used to create your own field types, based
   --  on specific Ada types. It creates various subprograms for ease of use
   --  when writing queries, as well as subprograms to more easily bind SQL
   --  functions manipulating this type.

   generic
      type Ada_Type (<>) is private;
      with function To_SQL (Value : Ada_Type) return String;
      --  Converts Ada_Type to a value suitable to pass to SQL. This should
      --  protect special characters if need be
   package Field_Types is
      type Field is new SQL_Field with null record;

      function From_Table
        (Table : SQL_Single_Table'Class;
         Name  : Field) return Field'Class;
      --  Returns field applied to the table, as in Table.Field.
      --  In general, this is not needed, except when Table is the result of a
      --  call to Rename on a table generated by a call to Left_Join for
      --  instance. In such a case, the list of valid fields for Table is not
      --  known, and we do not have primitive operations to access those, so
      --  this function makes them accessible. However, there is currently no
      --  check that Field is indeed valid for Table.

      Null_Field : constant Field;

      function Expression (Value : Ada_Type) return Field'Class;
      --  Create a constant field

      function From_String (SQL : String) return Field'Class;
      --  Similar to the above, but the parameter is assumed to be proper SQL
      --  already (so for instance no quoting or special-character quoting
      --  would occur for strings). This function just indicates to GNATCOLL
      --  how the string should be interpreted

      function "&"
        (Field : SQL_Field'Class; Value : Ada_Type) return SQL_Field_List;
      function "&"
        (Value : Ada_Type; Field : SQL_Field'Class) return SQL_Field_List;
      function "&"
        (List : SQL_Field_List; Value : Ada_Type) return SQL_Field_List;
      function "&"
        (Value : Ada_Type; List : SQL_Field_List) return SQL_Field_List;
      --  Create lists of fields

      function "="  (Left : Field; Right : Field'Class) return SQL_Criteria;
      function "/=" (Left : Field; Right : Field'Class) return SQL_Criteria;
      function "<"  (Left : Field; Right : Field'Class) return SQL_Criteria;
      function "<=" (Left : Field; Right : Field'Class) return SQL_Criteria;
      function ">"  (Left : Field; Right : Field'Class) return SQL_Criteria;
      function ">=" (Left : Field; Right : Field'Class) return SQL_Criteria;
      function "="  (Left : Field; Right : Ada_Type) return SQL_Criteria;
      function "/=" (Left : Field; Right : Ada_Type) return SQL_Criteria;
      function "<"  (Left : Field; Right : Ada_Type) return SQL_Criteria;
      function "<=" (Left : Field; Right : Ada_Type) return SQL_Criteria;
      function ">"  (Left : Field; Right : Ada_Type) return SQL_Criteria;
      function ">=" (Left : Field; Right : Ada_Type) return SQL_Criteria;
      pragma Inline ("=", "/=", "<", ">", "<=", ">=");
      --  Compare fields and values

      function Greater_Than
        (Left : SQL_Field'Class; Right : Field) return SQL_Criteria;
      function Greater_Or_Equal
        (Left : SQL_Field'Class; Right : Field) return SQL_Criteria;
      function Equal
        (Left : SQL_Field'Class; Right : Field) return SQL_Criteria;
      function Less_Than
        (Left : SQL_Field'Class; Right : Field) return SQL_Criteria;
      function Less_Or_Equal
        (Left : SQL_Field'Class; Right : Field) return SQL_Criteria;
      function Greater_Than
        (Left : SQL_Field'Class; Right : Ada_Type) return SQL_Criteria;
      function Greater_Or_Equal
        (Left : SQL_Field'Class; Right : Ada_Type) return SQL_Criteria;
      function Equal
        (Left : SQL_Field'Class; Right : Ada_Type) return SQL_Criteria;
      function Less_Than
        (Left : SQL_Field'Class; Right : Ada_Type) return SQL_Criteria;
      function Less_Or_Equal
        (Left : SQL_Field'Class; Right : Ada_Type) return SQL_Criteria;
      pragma Inline
        (Greater_Than, Greater_Or_Equal, Equal, Less_Than, Less_Or_Equal);
      --  Same as "<", "<=", ">", ">=" and "=", but these can be used with the
      --  result of aggregate fields for instance. In general, you should not
      --  use these to work around typing issues (for instance comparing a text
      --  field with 1234)

      function "=" (Self : Field; Value : Ada_Type) return SQL_Assignment;
      function "=" (Self : Field; To : Field'Class) return SQL_Assignment;
      --  Set Field to the value of To

      --  Assign a new value to the value

      generic
         Name : String;
      function Operator (Field1, Field2 : Field'Class) return Field'Class;
      --  An operator between two fields, that return a field of the new type

      generic
         type Scalar is (<>);
         Name   : String;
         Prefix : String := "";
         Suffix : String := "";
      function Scalar_Operator
        (Self : Field'Class; Operand : Scalar) return Field'Class;
      --  An operator between a field and a constant value, as in
      --      field + interval '2 days'
      --           where  Name   is "+"
      --                  Prefix is "interval '"
      --                  Suffix is " days'"

      generic
         Name : String;
      function SQL_Function return Field'Class;
      --  A no-parameter sql function, as in "CURRENT_TIMESTAMP"

      generic
         type Argument_Type is abstract new SQL_Field with private;
         Name   : String;
         Suffix : String := ")";
      function Apply_Function (Self : Argument_Type'Class) return Field'Class;
      --  Applying a function to a field, as in  "LOWER (field)", where
      --     Name   is "LOWER ("
      --     Suffix is ")"

   private
      Null_Field : constant Field :=
        (Table    => null,
         Instance => null,
         Name     => Null_String'Access);
   end Field_Types;

private
   type SQL_Field_List is new SQL_Field_Or_List with record
      List : Field_List.List;
   end record;

   type SQL_Table_Or_List is abstract tagged null record;

   type SQL_Single_Table (Instance : Cst_String_Access)
      is abstract new SQL_Table_Or_List with null record;
   --  instance name, might be null when this is the same name as the table.
   --  This isn't used for lists, but is used for all other types of tables
   --  (simple, left join, subqueries) so is put here for better sharing.

   ---------------
   -- Criterias --
   ---------------

   type SQL_Criteria_Data is abstract tagged record
      Refcount : Natural := 1;
   end record;

   type Controlled_SQL_Criteria is new Ada.Finalization.Controlled with record
      Data : SQL_Criteria_Data_Access;
   end record;
   overriding procedure Finalize (Self : in out Controlled_SQL_Criteria);
   overriding procedure Adjust   (Self : in out Controlled_SQL_Criteria);

   type SQL_Criteria is record
      Criteria : Controlled_SQL_Criteria;
   end record;
   --  SQL_Criteria must not be tagged, otherwise we have subprograms that are
   --  primitive for two types. This would also be impossible for users to
   --  declare a variable of type SQL_Criteria.

   No_Criteria : constant SQL_Criteria :=
     (Criteria => (Ada.Finalization.Controlled with Data => null));

   --------------------
   -- Field pointers --
   --------------------

   type Field_Access is access all SQL_Field'Class;
   type Field_Pointer_Data is record
      Refcount : Natural := 1;
      Field    : Field_Access;
   end record;
   type Field_Pointer_Data_Access is access Field_Pointer_Data;
   type SQL_Field_Pointer is new Ada.Finalization.Controlled with record
      Data : Field_Pointer_Data_Access;
   end record;
   procedure Adjust   (Self : in out SQL_Field_Pointer);
   procedure Finalize (Self : in out SQL_Field_Pointer);

   No_Field_Pointer : constant SQL_Field_Pointer :=
     (Ada.Finalization.Controlled with null);

   -----------------
   -- Assignments --
   -----------------

   type Assignment_Item is record
      Field    : SQL_Field_Pointer;
      --  The modified field

      To_Field : SQL_Field_Pointer;
      --  Its new value (No_Field_Pointer sets to NULL)
   end record;

   package Assignment_Lists is new Ada.Containers.Doubly_Linked_Lists
     (Assignment_Item);

   type SQL_Assignment is record
      List : Assignment_Lists.List;
   end record;

   No_Assignment : constant SQL_Assignment :=
     (List => Assignment_Lists.Empty_List);

   Empty_Field_List : constant SQL_Field_List :=
     (SQL_Field_Or_List with List => Field_List.Empty_List);

end GNATCOLL.SQL_Impl;
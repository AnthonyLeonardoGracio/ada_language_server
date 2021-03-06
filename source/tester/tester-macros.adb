------------------------------------------------------------------------------
--                         Language Server Protocol                         --
--                                                                          --
--                     Copyright (C) 2018-2019, AdaCore                     --
--                                                                          --
-- This is free software;  you can redistribute it  and/or modify it  under --
-- terms of the  GNU General Public License as published  by the Free Soft- --
-- ware  Foundation;  either version 3,  or (at your option) any later ver- --
-- sion.  This software is distributed in the hope  that it will be useful, --
-- but WITHOUT ANY WARRANTY;  without even the implied warranty of MERCHAN- --
-- TABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public --
-- License for  more details.  You should have  received  a copy of the GNU --
-- General  Public  License  distributed  with  this  software;   see  file --
-- COPYING3.  If not, go to http://www.gnu.org/licenses for a complete copy --
-- of the license.                                                          --
------------------------------------------------------------------------------

with Ada.Directories;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

with GNAT.Regpat;

with URIs;

package body Tester.Macros is

   function Expand
     (Value    : GNATCOLL.JSON.JSON_Value;
      Env      : Spawn.Environments.Process_Environment;
      Test_Dir : String) return GNATCOLL.JSON.JSON_Value;
   --  Expand recursively

   function Expand_URI
     (Path     : String;
      Test_Dir : String) return String;
   --  Turn Path into URI with scheme 'file://'

   Pattern : constant GNAT.Regpat.Pattern_Matcher :=
     GNAT.Regpat.Compile ("\${([^}]+)}|\$URI{([^}]+)}");

   function Expand
     (Value    : GNATCOLL.JSON.JSON_Value;
      Env      : Spawn.Environments.Process_Environment;
      Test_Dir : String) return GNATCOLL.JSON.JSON_Value
   is
      procedure Each_Field
        (Object : in out GNATCOLL.JSON.JSON_Value;
         Name   : String;
         Value  : GNATCOLL.JSON.JSON_Value);
      --  Expand macros in given field

      function Expand_in_String (Text : String) return Unbounded_String;
      --  Expand macro in given string

      procedure Map is new GNATCOLL.JSON.Gen_Map_JSON_Object
        (GNATCOLL.JSON.JSON_Value);

      ----------------
      -- Each_Field --
      ----------------

      procedure Each_Field
        (Object : in out GNATCOLL.JSON.JSON_Value;
         Name   : String;
         Value  : GNATCOLL.JSON.JSON_Value) is
      begin
         Object.Set_Field (Name, Expand (Value, Env, Test_Dir));
      end Each_Field;

      ----------------------
      -- Expand_in_String --
      ----------------------

      function Expand_in_String (Text : String) return Unbounded_String
      is
         use type GNAT.Regpat.Match_Location;
         Result : Unbounded_String;
         Next   : Positive := 1;
      begin
         while Next < Text'Length loop
            declare
               Found : GNAT.Regpat.Match_Array (0 .. 2);
            begin
               GNAT.Regpat.Match (Pattern, Text, Found, Next);
               exit when Found (0) = GNAT.Regpat.No_Match;

               Append (Result, Text (Next .. Found (0).First - 1));

               if Found (1) /= GNAT.Regpat.No_Match then     --  ${NAME}
                  declare
                     Name : constant String :=
                       Text (Found (1).First .. Found (1).Last);
                  begin
                     if Env.Contains (Name) then
                        Append (Result, Env.Value (Name));
                     else
                        raise Program_Error
                          with Name & " undefined, cannot expand macro";
                     end if;
                  end;
               elsif Found (2) /= GNAT.Regpat.No_Match then  --  $URI{x}
                  Append
                    (Result,
                     Expand_URI
                       (Text (Found (2).First .. Found (2).Last),
                        Test_Dir));
               end if;

               Next := Found (0).Last + 1;
            end;
         end loop;

         Append (Result, Text (Next .. Text'Last));

         return Result;
      end Expand_in_String;

   begin
      case Value.Kind is
         when GNATCOLL.JSON.JSON_Null_Type |
              GNATCOLL.JSON.JSON_Boolean_Type |
              GNATCOLL.JSON.JSON_Int_Type |
              GNATCOLL.JSON.JSON_Float_Type =>

            return Value;
         when GNATCOLL.JSON.JSON_String_Type =>

            return GNATCOLL.JSON.Create (Expand_in_String (Value.Get));
         when GNATCOLL.JSON.JSON_Array_Type =>
            declare
               Result : GNATCOLL.JSON.JSON_Array;
               Vector : constant GNATCOLL.JSON.JSON_Array := Value.Get;
            begin
               for J in 1 .. GNATCOLL.JSON.Length (Vector) loop
                  declare
                     Item : constant GNATCOLL.JSON.JSON_Value :=
                       GNATCOLL.JSON.Get (Vector, J);
                  begin
                     GNATCOLL.JSON.Append
                       (Result, Expand (Item, Env, Test_Dir));
                  end;
               end loop;

               return GNATCOLL.JSON.Create (Result);
            end;
         when GNATCOLL.JSON.JSON_Object_Type =>
            declare
               Result : GNATCOLL.JSON.JSON_Value :=
                 GNATCOLL.JSON.Create_Object;
            begin
               Map (Value, Each_Field'Access, Result);

               return Result;
            end;
      end case;
   end Expand;

   ------------
   -- Expand --
   ------------

   procedure Expand
     (Test : in out GNATCOLL.JSON.JSON_Value;
      Env  : Spawn.Environments.Process_Environment;
      Path : String)
   is
      Full_Name : constant String := Ada.Directories.Full_Name (Path);
      Directory : constant String :=
        Ada.Directories.Containing_Directory (Full_Name);
   begin
      Test := Expand (Test, Env, Directory);
   end Expand;

   ----------------
   -- Expand_URI --
   ----------------

   function Expand_URI
     (Path     : String;
      Test_Dir : String) return String is
   begin
      if Ada.Directories.Full_Name (Path) /= Path then
         --  Turn Path into absolute path
         return URIs.Conversions.From_File
                  (Ada.Directories.Full_Name (Test_Dir & "/" & Path));
      else
         return URIs.Conversions.From_File (Path);
      end if;
   end Expand_URI;

end Tester.Macros;

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

with Ada.Strings.UTF_Encoding;
with Ada.Directories;

with GNAT.Strings;
with GNATCOLL.JSON;
with GNATCOLL.Utils;        use GNATCOLL.Utils;
with GNATCOLL.VFS;          use GNATCOLL.VFS;
with GNATCOLL.Traces;

with LSP.Messages.Requests;
with LSP.Types; use LSP.Types;

with LSP.Ada_Documents;
with LSP.Lal_Utils;

with Langkit_Support.Slocs;
with Langkit_Support.Text;

with Libadalang.Analysis;
with Libadalang.Common;

package body LSP.Ada_Handlers is

   function "+" (Text : Ada.Strings.UTF_Encoding.UTF_8_String)
                 return LSP.Types.LSP_String renames
     LSP.Types.To_LSP_String;

   function Initialize_Request
     (Self  : access Message_Handler;
      Value : LSP.Messages.InitializeParams)
      return LSP.Messages.Initialize_Response;

   function Shutdown_Request
     (Self  : access Message_Handler)
      return LSP.Messages.ResponseMessage;

   function Text_Document_Code_Action_Request
     (Self  : access Message_Handler;
      Value : LSP.Messages.CodeActionParams)
      return LSP.Messages.CodeAction_Response;

   function Text_Document_Definition_Request
     (Self  : access Message_Handler;
      Value : LSP.Messages.TextDocumentPositionParams)
      return LSP.Messages.Location_Response;

   function Text_Document_Highlight_Request
     (Self  : access Message_Handler;
      Value : LSP.Messages.TextDocumentPositionParams)
      return LSP.Messages.Highlight_Response;

   function Text_Document_Hover_Request
     (Self  : access Message_Handler;
      Value : LSP.Messages.TextDocumentPositionParams)
      return LSP.Messages.Hover_Response;

   function Text_Document_References_Request
     (Self  : access Message_Handler;
      Value : LSP.Messages.ReferenceParams)
      return LSP.Messages.Location_Response;

   function Text_Document_Signature_Help_Request
     (Self  : access Message_Handler;
      Value : LSP.Messages.TextDocumentPositionParams)
      return LSP.Messages.SignatureHelp_Response;

   function Text_Document_Symbol_Request
     (Self  : access Message_Handler;
      Value : LSP.Messages.DocumentSymbolParams)
     return LSP.Messages.Symbol_Response;

   function Workspace_Execute_Command_Request
     (Self  : access Message_Handler;
      Value : LSP.Messages.ExecuteCommandParams)
      return LSP.Messages.ExecuteCommand_Response;

   function Workspace_Symbol_Request
     (Self  : access Message_Handler;
      Value : LSP.Messages.WorkspaceSymbolParams)
      return LSP.Messages.Symbol_Response;

   function Text_Document_Completion_Request
     (Self  : access Message_Handler;
      Value : LSP.Messages.TextDocumentPositionParams)
     return LSP.Messages.Completion_Response;

   -----------------------
   -- Exit_Notification --
   -----------------------

   overriding procedure Exit_Notification (Self : access Message_Handler) is
   begin
      Self.Server.Stop;
   end Exit_Notification;

   ------------------------
   -- Initialize_Request --
   ------------------------

   function Initialize_Request
     (Self  : access Message_Handler;
      Value : LSP.Messages.InitializeParams)
      return LSP.Messages.Initialize_Response
   is
      Response : LSP.Messages.Initialize_Response (Is_Error => False);
      Root     : LSP.Types.LSP_String;
   begin
      Response.result.capabilities.definitionProvider := True;
      Response.result.capabilities.referencesProvider := True;
      Response.result.capabilities.documentSymbolProvider := True;
      Response.result.capabilities.textDocumentSync :=
        (Is_Set => True, Is_Number => True, Value => LSP.Messages.Full);
      Response.result.capabilities.completionProvider :=
        (True,
         (resolveProvider => (True, False),
          triggerCharacters => Empty_Vector & To_LSP_String (".")));
      Response.result.capabilities.hoverProvider := True;

      if not LSP.Types.Is_Empty (Value.rootUri) then
         Root := Self.Context.URI_To_File (Value.rootUri);
      else
         --  URI isn't provided, rollback to deprecated rootPath
         Root := Value.rootPath;
      end if;

      Self.Context.Initialize (Root);

      return Response;
   end Initialize_Request;

   ----------------------
   -- Shutdown_Request --
   ----------------------

   function Shutdown_Request
     (Self  : access Message_Handler)
      return LSP.Messages.ResponseMessage
   is
      pragma Unreferenced (Self);
   begin
      return Response : LSP.Messages.ResponseMessage (Is_Error => False);
   end Shutdown_Request;

   ---------------------------------------
   -- Text_Document_Code_Action_Request --
   ---------------------------------------

   function Text_Document_Code_Action_Request
     (Self  : access Message_Handler;
      Value : LSP.Messages.CodeActionParams)
      return LSP.Messages.CodeAction_Response
   is
      pragma Unreferenced (Self, Value);
      Response : LSP.Messages.CodeAction_Response (Is_Error => True);
   begin
      Response.error :=
        (True,
         (code => LSP.Messages.InternalError,
          message => To_LSP_String ("Not implemented"),
          data => <>));
      return Response;
   end Text_Document_Code_Action_Request;

   --------------------------------------
   -- Text_Document_Definition_Request --
   --------------------------------------

   function Text_Document_Definition_Request
     (Self  : access Message_Handler;
      Value : LSP.Messages.TextDocumentPositionParams)
      return LSP.Messages.Location_Response
   is
      use Libadalang.Analysis;

      procedure Append
        (Result     : in out LSP.Messages.Location_Vector;
         Definition : Defining_Name);
      --  Append given defining name to result

      function Find_Next_Part
        (Definition : Defining_Name) return Defining_Name;
      --  Find defining name of a completion if any

      function Find_First_Part
        (Definition : Defining_Name) return Defining_Name;
      --  Find defining name of a declaration for given completion

      ------------
      -- Append --
      ------------

      procedure Append
        (Result     : in out LSP.Messages.Location_Vector;
         Definition : Defining_Name)
      is
         use Libadalang.Common;

         From : constant Langkit_Support.Slocs.Source_Location_Range :=
           Sloc_Range (Data (Definition.Token_Start));
         To   : constant Langkit_Support.Slocs.Source_Location_Range :=
           Sloc_Range (Data (Definition.Token_End));

         First_Position : constant LSP.Messages.Position :=
           (Line_Number (From.Start_Line) - 1,
            UTF_16_Index (From.Start_Column) - 1);
         Last_Position  : constant LSP.Messages.Position :=
           (Line_Number (To.End_Line) - 1,
            UTF_16_Index (To.End_Column) - 1);

         Location : constant LSP.Messages.Location :=
           (uri  => Self.Context.File_To_URI (+Definition.Unit.Get_Filename),
            span => LSP.Messages.Span'(First_Position, Last_Position));

      begin
         Result.Append (Location);
      end Append;

      ---------------------
      -- Find_First_Part --
      ---------------------

      function Find_First_Part
        (Definition : Defining_Name) return Defining_Name
      is
         Next : Defining_Name := Definition;
         Prev : Defining_Name;
      begin
         --  Iterate over Next.P_Previous_Part names until no name found
         loop
            begin
               Prev := Next.P_Previous_Part;

               exit when Prev in No_Defining_Name | Next;

               Next := Prev;
            exception
               when Libadalang.Common.Property_Error =>
                  exit;
            end;
         end loop;

         if Next = Definition then
            return No_Defining_Name;
         else
            return Next;
         end if;
      end Find_First_Part;

      --------------------
      -- Find_Next_Part --
      --------------------

      function Find_Next_Part
        (Definition : Defining_Name) return Defining_Name
      is
         Next : Defining_Name;
      begin
         Next := Definition.P_Next_Part;

         if Next = Definition then
            return No_Defining_Name;
         else
            return Next;
         end if;
      exception
         when Libadalang.Common.Property_Error =>
            return No_Defining_Name;
      end Find_Next_Part;

      Document   : constant LSP.Ada_Documents.Document_Access :=
        Self.Context.Get_Document (Value.textDocument.uri);

      Name_Node : constant Name := LSP.Lal_Utils.Get_Node_As_Name
        (Document.Get_Node_At (Value.position));

      Definition : Defining_Name;
      Other_Part : Defining_Name;
      Response   : LSP.Messages.Location_Response (Is_Error => False);

   begin

      if Name_Node = No_Name then
         return Response;
      end if;

      --  Check is we are on some defining name
      Definition := LSP.Lal_Utils.Get_Name_As_Defining (Name_Node);

      if Definition = No_Defining_Name then
         Definition := LSP.Lal_Utils.Resolve_Name (Name_Node);

         if Definition /= No_Defining_Name then
            Append (Response.result, Definition);
         end if;
      else  --  If we are on a defining_name already
         Other_Part := Find_Next_Part (Definition);

         if Other_Part = No_Defining_Name then
            --  No next part is found. Check first defining name
            Other_Part := Find_First_Part (Definition);
         end if;

         if Other_Part /= No_Defining_Name then
            Append (Response.result, Other_Part);
         end if;
      end if;

      return Response;
   end Text_Document_Definition_Request;

   ------------------------------
   -- Text_Document_Did_Change --
   ------------------------------

   overriding procedure Text_Document_Did_Change
     (Self  : access Message_Handler;
      Value : LSP.Messages.DidChangeTextDocumentParams)
   is
      Document : constant LSP.Ada_Documents.Document_Access :=
        Self.Context.Get_Document (Value.textDocument.uri);
      Diag     : LSP.Messages.PublishDiagnosticsParams;
   begin
      Document.Apply_Changes (Value.contentChanges);
      Document.Get_Errors (Diag.diagnostics);

      Diag.uri := Value.textDocument.uri;
      Self.Server.Publish_Diagnostics (Diag);
   end Text_Document_Did_Change;

   -----------------------------
   -- Text_Document_Did_Close --
   -----------------------------

   overriding procedure Text_Document_Did_Close
     (Self  : access Message_Handler;
      Value : LSP.Messages.DidCloseTextDocumentParams)
   is
   begin
      Self.Context.Unload_Document (Value.textDocument);
   end Text_Document_Did_Close;

   ----------------------------
   -- Text_Document_Did_Open --
   ----------------------------

   overriding procedure Text_Document_Did_Open
     (Self  : access Message_Handler;
      Value : LSP.Messages.DidOpenTextDocumentParams)
   is
      Errors : LSP.Messages.ShowMessageParams;
   begin

      GNATCOLL.Traces.Trace (Server_Trace, "In Text_Document_Did_Open");
      GNATCOLL.Traces.Trace
        (Server_Trace, "Uri : " & To_UTF_8_String (Value.textDocument.uri));

      --  Some clients don't properly call initialize, in which case we want to
      --  call it anyway at the first open file request.

      if not Self.Context.Is_Initialized then
         GNATCOLL.Traces.Trace
           (Server_Trace, "No project loaded, creating default one ...");

         declare
            Root : LSP.Types.LSP_String :=
              Self.Context.URI_To_File (Value.textDocument.uri);
         begin
            Root := To_LSP_String
              (Ada.Directories.Containing_Directory (To_UTF_8_String (Root)));

            GNATCOLL.Traces.Trace
              (Server_Trace, "Root : " & To_UTF_8_String (Root));

            Self.Context.Initialize (Root);

         end;
      end if;

      if not Self.Context.Has_Project then
         Self.Context.Load_Project
           (Empty_LSP_String, GNATCOLL.JSON.JSON_Null, Errors);

         if not LSP.Types.Is_Empty (Errors.message) then
            Self.Server.Show_Message (Errors);
         end if;
      end if;

      Self.Context.Load_Document (Value.textDocument);
   end Text_Document_Did_Open;

   -------------------------------------
   -- Text_Document_Highlight_Request --
   -------------------------------------

   function Text_Document_Highlight_Request
     (Self  : access Message_Handler;
      Value : LSP.Messages.TextDocumentPositionParams)
      return LSP.Messages.Highlight_Response
   is
      pragma Unreferenced (Self, Value);
      Response : LSP.Messages.Highlight_Response (Is_Error => True);
   begin
      Response.error :=
        (True,
         (code => LSP.Messages.InternalError,
          message => To_LSP_String ("Not implemented"),
          data => <>));
      return Response;
   end Text_Document_Highlight_Request;

   ---------------------------------
   -- Text_Document_Hover_Request --
   ---------------------------------

   function Text_Document_Hover_Request
     (Self  : access Message_Handler;
      Value : LSP.Messages.TextDocumentPositionParams)
      return LSP.Messages.Hover_Response
   is
      use Libadalang.Analysis;
      use Libadalang.Common;

      Response           : LSP.Messages.Hover_Response (Is_Error => False);
      Document           : constant LSP.Ada_Documents.Document_Access :=
                             Self.Context.Get_Document
                               (Value.textDocument.uri);
      Name_Node          : constant Name :=
                             LSP.Lal_Utils.Get_Node_As_Name
                               (Document.Get_Node_At (Value.position));
      Defining_Name_Node : Defining_Name;
      Decl               : Basic_Decl;
      Subp_Spec_Node     : Base_Subp_Spec;
      Hover_Text         : LSP_String;

      procedure Create_Hover_Text_For_Basic_Decl;
      --  Create the hover text for for basic declarations

      procedure Create_Hover_Text_For_Subp_Spec;
      --  Create the hover text for for subprogram declarations

      --------------------------------------
      -- Create_Hover_Text_For_Basic_Decl --
      --------------------------------------

      procedure Create_Hover_Text_For_Basic_Decl is
      begin
         --  Return an empty hover text for package declarations
         if Decl.Kind in Ada_Base_Package_Decl then
            return;
         end if;

         declare
            Text        : constant String := Langkit_Support.Text.To_UTF8
              (Decl.Text);
            Lines       : GNAT.Strings.String_List_Access := Split
              (Text,
               On               => ASCII.LF,
               Omit_Empty_Lines => True);
            Idx         : Integer;
         begin
            if Lines'Length = 1 then
               declare
                  Res_Idx : Integer := Text'First;
                  Result  : String (Text'First .. Text'Last);
               begin
                  Idx := Text'First;

                  while Idx <= Text'Last loop
                     Skip_Blanks (Text, Idx);

                     while Idx <= Text'Last
                       and then not Is_Whitespace (Text (Idx))
                     loop
                        Result (Res_Idx) := Text (Idx);
                        Idx := Idx + 1;
                        Res_Idx := Res_Idx + 1;
                     end loop;

                     if Res_Idx < Result'Last then
                        Result (Res_Idx) := ' ';
                        Res_Idx := Res_Idx + 1;
                     end if;
                  end loop;

                  if Res_Idx > Text'First then
                     Hover_Text := To_LSP_String
                       (Result (Text'First .. Res_Idx - 1));
                  end if;
               end;
            else
               declare
                  Blanks_Count_Per_Line : array
                    (Lines'First + 1 .. Lines'Last) of Natural;
                  Min_Line_Blanks_Count : Natural := Natural'Last;
               begin
                  Hover_Text := To_LSP_String (Lines (Lines'First).all);

                  for J in Lines'First + 1 .. Lines'Last loop
                     Idx := Lines (J)'First;
                     Skip_Blanks (Lines (J).all, Idx);

                     Blanks_Count_Per_Line (J) := Idx - Lines (J)'First;
                     Min_Line_Blanks_Count := Natural'Min
                       (Min_Line_Blanks_Count,
                        Blanks_Count_Per_Line (J));
                  end loop;

                  for J in Lines'First + 1 .. Lines'Last loop
                     declare
                        Start_Idx : constant Integer :=
                                      Lines (J)'First + Min_Line_Blanks_Count;
                     begin
                        Hover_Text := Hover_Text & To_LSP_String
                          (ASCII.LF
                           & Lines (J).all (Start_Idx .. Lines (J)'Last));
                     end;
                  end loop;
               end;
            end if;

            GNAT.Strings.Free (Lines);
         end;
      end Create_Hover_Text_For_Basic_Decl;

      -------------------------------------
      -- Create_Hover_Text_For_Subp_Spec --
      -------------------------------------

      procedure Create_Hover_Text_For_Subp_Spec is
         Text  : constant String := Langkit_Support.Text.To_UTF8
           (Subp_Spec_Node.Text);
         Lines : GNAT.Strings.String_List_Access := Split
           (Text,
            On               => ASCII.LF,
            Omit_Empty_Lines => True);
         Idx   : Integer;
      begin
         --  For single-line subprogram specifications, we display the
         --  associated text directly.
         --  For multi-line ones, remove the identation blankspaces to replace
         --  them by a fixed number of blankspaces.

         if Lines'Length = 1 then
            Hover_Text := To_LSP_String (Text);
         else
            Hover_Text := To_LSP_String (Lines (Lines'First).all);

            for J in Lines'First + 1 .. Lines'Last loop
               Idx := Lines (J)'First;
               Skip_Blanks (Lines (J).all, Idx);

               Hover_Text := Hover_Text
                 & To_LSP_String
                 (ASCII.LF
                  & (if Lines (J).all (Idx) = '(' then "  " else "   ")
                  & Lines (J).all (Idx .. Lines (J).all'Last));
            end loop;
         end if;

         GNAT.Strings.Free (Lines);
      end Create_Hover_Text_For_Subp_Spec;

   begin
      if Name_Node = No_Name then
         return Response;
      end if;

      --  Get the defining node of the node being hovered
      Defining_Name_Node := LSP.Lal_Utils.Resolve_Name
        (Name_Node => Name_Node);

      if Defining_Name_Node = No_Defining_Name then
         return Response;
      end if;

      --  Get the associated basic declaration
      Decl := Defining_Name_Node.P_Basic_Decl;

      if Decl = No_Basic_Decl then
         return Response;
      end if;

      --  Try to retrieve the subprogram spec node, if any: if it's a
      --  subprogram node that does not have any separate declaration we
      --  only want to display its specification, not the body.
      Subp_Spec_Node := Decl.P_Subp_Spec_Or_Null;

      if Subp_Spec_Node /= No_Base_Subp_Spec then
         Create_Hover_Text_For_Subp_Spec;
      else
         Create_Hover_Text_For_Basic_Decl;
      end if;

      --  Append the associated basic declaration's text to the response.
      --  We set the language for highlighting.
      if Hover_Text /= Empty_LSP_String then
         Response.result.contents.Append
           (LSP.Messages.MarkedString'
              (Is_String => False,
               value     => Hover_Text,
               language  => To_LSP_String ("ada")));
      end if;

      --  TODO: append the trivias associated with the basic declaration node
      --  when available in libadalang.

      return Response;
   end Text_Document_Hover_Request;

   --------------------------------------
   -- Text_Document_References_Request --
   --------------------------------------

   function Text_Document_References_Request
     (Self  : access Message_Handler;
      Value : LSP.Messages.ReferenceParams)
      return LSP.Messages.Location_Response
   is
      use Libadalang.Analysis;

      function Find_All_References
        (Definition         : Defining_Name;
         Sources            : GNATCOLL.VFS.File_Array_Access;
         Include_Definition : Boolean := False)
      return Ada_Node_Array;
      --  Helper function, finds all references of a given defining name in a
      --  given list of units.

      function Find_All_References
        (Definition         : Defining_Name;
         Sources            : GNATCOLL.VFS.File_Array_Access;
         Include_Definition : Boolean := False)
      return Ada_Node_Array
      is
         Context : constant Analysis_Context := Definition.Unit.Context;
         Source_Units : Analysis_Unit_Array (Sources'Range);
      begin
         for N in Sources'Range loop
            Source_Units (N) := Context.Get_From_File
              (Sources (N).Display_Full_Name);
         end loop;

         declare
            References : constant Ada_Node_Array :=
              Definition.P_Find_All_References (Source_Units);
         begin
            if Include_Definition then
               return References & (1 => Definition.As_Ada_Node);
            else
               return References;
            end if;
         end;
      end Find_All_References;

      Document   : constant LSP.Ada_Documents.Document_Access :=
        Self.Context.Get_Document (Value.textDocument.uri);

      Name_Node : constant Name := LSP.Lal_Utils.Get_Node_As_Name
        (Document.Get_Node_At (Value.position));

      Definition : Defining_Name;
      Response   : LSP.Messages.Location_Response (Is_Error => False);

   begin

      if Name_Node = No_Name then
         return Response;
      end if;

      Definition := LSP.Lal_Utils.Resolve_Name (Name_Node);

      if Definition = No_Defining_Name then
         return Response;
      end if;

      declare
         Ada_Sources : File_Array_Access := Self.Context.Get_Ada_Source_Files;
         References  : constant Ada_Node_Array := Find_All_References
             (Definition         => Definition,
              Sources            => Ada_Sources,
              Include_Definition => Value.context.includeDeclaration);
      begin
         Unchecked_Free (Ada_Sources);
         for Node of References loop
            declare
               use Libadalang.Common;

               Start_Sloc_Range :
               constant Langkit_Support.Slocs.Source_Location_Range :=
                 Sloc_Range (Data (Node.Token_Start));
               End_Sloc_Range   :
               constant Langkit_Support.Slocs.Source_Location_Range :=
                 Sloc_Range (Data (Node.Token_End));

               First_Position : constant LSP.Messages.Position :=
                 (Line_Number (Start_Sloc_Range.Start_Line) - 1,
                  UTF_16_Index (Start_Sloc_Range.Start_Column) - 1);
               Last_Position  : constant LSP.Messages.Position :=
                 (Line_Number (End_Sloc_Range.End_Line) - 1,
                  UTF_16_Index (End_Sloc_Range.End_Column) - 1);

               Location : constant LSP.Messages.Location :=
                 (uri  => Self.Context.File_To_URI (+Node.Unit.Get_Filename),
                  span => LSP.Messages.Span'(First_Position, Last_Position));
            begin
               Response.result.Append (Location);
            end;
         end loop;

         return Response;
      end;

   end Text_Document_References_Request;

   ------------------------------------------
   -- Text_Document_Signature_Help_Request --
   ------------------------------------------

   function Text_Document_Signature_Help_Request
     (Self  : access Message_Handler;
      Value : LSP.Messages.TextDocumentPositionParams)
      return LSP.Messages.SignatureHelp_Response
   is
      pragma Unreferenced (Self, Value);
      Response : LSP.Messages.SignatureHelp_Response (Is_Error => True);
   begin
      Response.error :=
        (True,
         (code => LSP.Messages.InternalError,
          message => To_LSP_String ("Not implemented"),
          data => <>));
      return Response;
   end Text_Document_Signature_Help_Request;

   ----------------------------------
   -- Text_Document_Symbol_Request --
   ----------------------------------

   function Text_Document_Symbol_Request
     (Self  : access Message_Handler;
      Value : LSP.Messages.DocumentSymbolParams)
      return LSP.Messages.Symbol_Response
   is
      Document : constant LSP.Ada_Documents.Document_Access :=
        Self.Context.Get_Document (Value.textDocument.uri);
      Response : LSP.Messages.Symbol_Response (Is_Error => False);
   begin
      Document.Get_Symbols (Response.result);
      return Response;
   end Text_Document_Symbol_Request;

   ----------------------------------------
   -- Workspace_Did_Change_Configuration --
   ----------------------------------------

   overriding procedure Workspace_Did_Change_Configuration
     (Self     : access Message_Handler;
      Value    : LSP.Messages.DidChangeConfigurationParams)
   is
      use type GNATCOLL.JSON.JSON_Value_Type;

      projectFile       : constant String := "projectFile";
      scenarioVariables : constant String := "scenarioVariables";

      Ada       : constant LSP.Types.LSP_Any := Value.settings.Get ("ada");
      File      : LSP.Types.LSP_String;
      Variables : LSP.Types.LSP_Any;
      Errors    : LSP.Messages.ShowMessageParams;
   begin
      if Ada.Kind = GNATCOLL.JSON.JSON_Object_Type then
         if Ada.Has_Field (projectFile) then
            File := +Ada.Get (projectFile).Get;

            --  Drop uri scheme if present
            if LSP.Types.Starts_With (File, "file:") then
               File := Self.Context.URI_To_File (File);
            end if;
         end if;

         if Ada.Has_Field (scenarioVariables) and then
           Ada.Get (scenarioVariables).Kind  = GNATCOLL.JSON.JSON_Object_Type
         then
            Variables := Ada.Get (scenarioVariables);
         end if;
      end if;

      Self.Context.Load_Project (File, Variables, Errors);

      if not LSP.Types.Is_Empty (Errors.message) then
         Self.Server.Show_Message (Errors);
      end if;
   end Workspace_Did_Change_Configuration;

   ---------------------------------------
   -- Workspace_Execute_Command_Request --
   ---------------------------------------

   function Workspace_Execute_Command_Request
     (Self  : access Message_Handler;
      Value : LSP.Messages.ExecuteCommandParams)
      return LSP.Messages.ExecuteCommand_Response
   is
      pragma Unreferenced (Self, Value);
      Response : LSP.Messages.ExecuteCommand_Response (Is_Error => True);
   begin
      Response.error :=
        (True,
         (code => LSP.Messages.InternalError,
          message => To_LSP_String ("Not implemented"),
          data => <>));
      return Response;
   end Workspace_Execute_Command_Request;

   ------------------------------
   -- Workspace_Symbol_Request --
   ------------------------------

   function Workspace_Symbol_Request
     (Self  : access Message_Handler;
      Value : LSP.Messages.WorkspaceSymbolParams)
      return LSP.Messages.Symbol_Response
   is
      pragma Unreferenced (Self, Value);
      Response : LSP.Messages.Symbol_Response (Is_Error => True);
   begin
      Response.error :=
        (True,
         (code => LSP.Messages.InternalError,
          message => To_LSP_String ("Not implemented"),
          data => <>));
      return Response;
   end Workspace_Symbol_Request;

   --------------------------------------
   -- Text_Document_Completion_Request --
   --------------------------------------

   function Text_Document_Completion_Request
     (Self  : access Message_Handler;
      Value : LSP.Messages.TextDocumentPositionParams)
      return LSP.Messages.Completion_Response
   is
      Document : constant LSP.Ada_Documents.Document_Access :=
        Self.Context.Get_Document (Value.textDocument.uri);
      Response : LSP.Messages.Completion_Response (Is_Error => False);
   begin
      Document.Get_Completions_At (Value.position, Response.result);
      return Response;
   end Text_Document_Completion_Request;

   --------------------
   -- Handle_Request --
   --------------------

   overriding function Handle_Request
     (Self    : access Message_Handler;
      Request : LSP.Messages.RequestMessage'Class)
      return LSP.Messages.ResponseMessage'Class
   is
      function Dispatcher return LSP.Messages.ResponseMessage'Class;
      --  Dispatch the request to the proper handling procedure.
      --  ??? This could be done more efficiently.

      ----------------
      -- Dispatcher --
      ----------------

      function Dispatcher return LSP.Messages.ResponseMessage'Class is
         use LSP.Messages.Requests;
      begin
         if Request in LSP.Messages.Requests.Initialize_Request'Class then
            return Self.Initialize_Request
              (LSP.Messages.Requests.Initialize_Request (Request).params);

         elsif Request in LSP.Messages.Requests.Shutdown_Request'Class then
            return Self.Shutdown_Request;

         elsif Request in CodeAction_Request'Class then
            return Self.Text_Document_Code_Action_Request
              (CodeAction_Request'Class (Request).params);

         elsif Request in Completion_Request'Class then
            return Self.Text_Document_Completion_Request
              (Completion_Request'Class (Request).params);

         elsif Request in Definition_Request'Class then
            return Self.Text_Document_Definition_Request
              (Definition_Request'Class (Request).params);

         elsif Request in Highlight_Request'Class then
            return Self.Text_Document_Highlight_Request
              (Highlight_Request'Class (Request).params);

         elsif Request in Hover_Request'Class then
            return Self.Text_Document_Hover_Request
              (Hover_Request'Class (Request).params);

         elsif Request in References_Request'Class then
            return Self.Text_Document_References_Request
              (References_Request'Class (Request).params);

         elsif Request in Signature_Help_Request'Class then
            return Self.Text_Document_Signature_Help_Request
              (Signature_Help_Request'Class (Request).params);

         elsif Request in Document_Symbols_Request'Class then
            return Self.Text_Document_Symbol_Request
              (Document_Symbols_Request'Class (Request).params);

         elsif Request in
           LSP.Messages.Requests.Workspace_Execute_Command_Request'Class
         then
            return Self.Workspace_Execute_Command_Request
              (LSP.Messages.Requests.Workspace_Execute_Command_Request'Class
                 (Request).params);

         elsif Request in
           LSP.Messages.Requests.Workspace_Symbols_Request'Class
         then
            return Self.Workspace_Symbol_Request
              (LSP.Messages.Requests.Workspace_Symbols_Request'Class
                  (Request).params);
         end if;

         return LSP.Messages.ResponseMessage'
           (Is_Error => True,
            jsonrpc  => <>,
            id       => <>,
            error    =>
              (Is_Set => True,
               Value  =>
                 (code    => LSP.Messages.MethodNotFound,
                  message => +"The request handler doesn't support this",
                  others  => <>)));
      end Dispatcher;

      R : LSP.Messages.ResponseMessage'Class := Dispatcher;
   begin
      R.jsonrpc := +"2.0";
      R.id := Request.id;
      return R;
   end Handle_Request;

end LSP.Ada_Handlers;

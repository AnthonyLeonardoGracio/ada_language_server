------------------------------------------------------------------------------
--                         Language Server Protocol                         --
--                                                                          --
--                     Copyright (C) 2019, AdaCore                          --
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
--
--  Interface to process notifications sent to the client.

with LSP.Messages;

package LSP.Client_Notifications is

   type Client_Notification_Handler is limited interface;
   --  Handler of notification on LSP client side

   type Client_Notification_Handler_Access is
     access all Client_Notification_Handler'Class;

   procedure Show_Message
     (Self   : in out Client_Notification_Handler;
      Params : LSP.Messages.ShowMessageParams) is null;
   --  Process window/showMessage notification

   procedure Log_Message
     (Self   : in out Client_Notification_Handler;
      Params : LSP.Messages.LogMessageParams) is null;
   --  Process window/logMessage notification

   procedure Publish_Diagnostics
     (Self   : in out Client_Notification_Handler;
      Params : LSP.Messages.PublishDiagnosticsParams) is null;
   --  Process textDocument/publishDiagnostics notification

end LSP.Client_Notifications;

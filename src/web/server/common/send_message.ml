(**************************************************************************)
(*                                BELENIOS                                *)
(*                                                                        *)
(*  Copyright © 2012-2025 Inria                                           *)
(*                                                                        *)
(*  This program is free software: you can redistribute it and/or modify  *)
(*  it under the terms of the GNU Affero General Public License as        *)
(*  published by the Free Software Foundation, either version 3 of the    *)
(*  License, or (at your option) any later version, with the additional   *)
(*  exemption that compiling, linking, and/or using OpenSSL is allowed.   *)
(*                                                                        *)
(*  This program is distributed in the hope that it will be useful, but   *)
(*  WITHOUT ANY WARRANTY; without even the implied warranty of            *)
(*  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU     *)
(*  Affero General Public License for more details.                       *)
(*                                                                        *)
(*  You should have received a copy of the GNU Affero General Public      *)
(*  License along with this program.  If not, see                         *)
(*  <http://www.gnu.org/licenses/>.                                       *)
(**************************************************************************)

open Lwt.Syntax
open Belenios
open Belenios_server_core
open Belenios_messages

let is_port_open port =
  try
    let s = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
    let addr = Unix.inet_addr_loopback in
    let sa = Unix.ADDR_INET (addr, port) in
    Unix.connect s sa;
    Unix.close s;
    true
  with _ -> false

let ensure_tunnel () =
  if is_port_open 12525 then 
    Ocsigen_messages.errlog "SMTP Tunnel: Port 12525 is already open."
  else
    match Sys.getenv_opt "SSH_PRIVATE_KEY" with
    | None -> 
        let home = try Sys.getenv "HOME" with Not_found -> "/home/belenios" in
        let id_rsa = Filename.concat (Filename.concat home ".ssh") "id_rsa" in
        if Sys.file_exists id_rsa then (
             Ocsigen_messages.errlog "SMTP Tunnel: SSH_PRIVATE_KEY env var not set, but found id_rsa file. Using it.";
             Ocsigen_messages.errlog "SMTP Tunnel: Starting tunnel...";
             let cmd = [| "ssh"; "-i"; id_rsa; "-o"; "StrictHostKeyChecking=no"; "-o"; "UserKnownHostsFile=/dev/null"; "-f"; "-N"; "-L"; "12525:smtprelay01.prodesp.sp.gov.br:25"; "lucas.teles@tools.univesp.br" |] in
             let pid = Unix.create_process "ssh" cmd Unix.stdin Unix.stdout Unix.stderr in
             let _ = Unix.waitpid [] pid in
             Unix.sleep 1;
             if is_port_open 12525 then Ocsigen_messages.errlog "SMTP Tunnel: Tunnel established successfully."
             else Ocsigen_messages.errlog "SMTP Tunnel: Failed to establish tunnel using existing key file."
        ) else (
             Ocsigen_messages.errlog "SMTP Tunnel: SSH_PRIVATE_KEY not set and no id_rsa found, cannot start tunnel"
        )
    | Some key ->
        Ocsigen_messages.errlog "SMTP Tunnel: Starting tunnel...";
        let home = try Sys.getenv "HOME" with Not_found -> "/home/belenios" in
        let ssh_dir = Filename.concat home ".ssh" in
        if not (Sys.file_exists ssh_dir) then Unix.mkdir ssh_dir 0o700;
        let id_rsa = Filename.concat ssh_dir "univesp_lucas.teles" in
        let oc = open_out_gen [Open_wronly; Open_creat; Open_trunc] 0o600 id_rsa in
        output_string oc key;
        if key.[String.length key - 1] <> '\n' then output_char oc '\n';
        close_out oc;
        let cmd = [| "ssh"; "-i"; id_rsa; "-o"; "StrictHostKeyChecking=no"; "-o"; "UserKnownHostsFile=/dev/null"; "-f"; "-N"; "-L"; "12525:smtprelay01.prodesp.sp.gov.br:25"; "lucas.teles@tools.univesp.br" |] in
        let pid = Unix.create_process "ssh" cmd Unix.stdin Unix.stdout Unix.stderr in
        let _ = Unix.waitpid [] pid in
        Unix.sleep 1;
        if is_port_open 12525 then Ocsigen_messages.errlog "SMTP Tunnel: Tunnel established successfully."
        else Ocsigen_messages.errlog "SMTP Tunnel: Failed to establish tunnel."

let tunnel_initialized = ref false

let ensure_tunnel_once () =
  if not !tunnel_initialized then (
    tunnel_initialized := true;
    ensure_tunnel ()
  )

let () = ensure_tunnel_once ()

let split_address =
  let open Re in
  let rex = Pcre.regexp "^(.*)@([^@]+)$" in
  fun x ->
    match exec rex x with
    | exception Not_found -> Printf.ksprintf failwith "bad e-mail address: %s" x
    | g -> (Group.get g 1, Group.get g 2)

let encode_address address =
  address |> String.split_on_char '=' |> String.concat "=="
  |> String.split_on_char '@' |> String.concat "="

let sendmail ~recipient ~uuid message =
  let base_address =
    Option.value ~default:!Web_config.server_mail !Web_config.return_path
  in
  let envelope_from =
    match !Web_config.encode_recipient with
    | false -> base_address
    | true ->
        let recipient = encode_address recipient in
        let uuid =
          match uuid with
          | None -> ""
          | Some x -> Printf.sprintf "+%s" (Uuid.unwrap x)
        in
        let local, domain = split_address base_address in
        Printf.sprintf "%s+%s%s@%s" local recipient uuid domain
  in
  Ocsigen_messages.errlog (Printf.sprintf "SMTP: Sending mail via tunnel for %s..." recipient);
  try
    let s = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
    Unix.connect s (Unix.ADDR_INET (Unix.inet_addr_loopback, 12525));
    let ic = Unix.in_channel_of_descr s in
    let oc = Unix.out_channel_of_descr s in
    let in_obj = new Netchannels.input_channel ic in
    let out_obj = new Netchannels.output_channel oc in
    let client = new Netsmtp.client in_obj out_obj in
    try
      client#helo ~host:!Web_config.domain ();
      client#mail envelope_from;
      client#rcpt recipient;
      let buf = Buffer.create 1024 in
      let ch = new Netchannels.output_buffer buf in
      Netmime_channels.write_mime_message ch message;
      ch#close_out ();
      client#data (new Netchannels.input_string (Buffer.contents buf));
      client#quit ();
      close_in_noerr ic;
      close_out_noerr oc;
      Ocsigen_messages.errlog "SMTP: Mail sent successfully."
    with e ->
      Ocsigen_messages.errlog ("SMTP Protocol Error: " ^ Printexc.to_string e);
      (try client#quit () with _ -> ());
      close_in_noerr ic;
      close_out_noerr oc;
      raise e
  with e ->
    Ocsigen_messages.errlog ("SMTP Connection Error: " ^ Printexc.to_string e);
    raise e


let send ?internal (msg : message) =
  let@ () =
   fun cont ->
    match (internal, !Web_config.send_message) with
    | None, None -> cont ()
    | Some true, _ -> cont ()
    | Some false, None -> Lwt.return_error ()
    | (None | Some false), Some (url, key) -> (
        let body =
          msg |> wrap_message ~key |> string_of_message_payload
          |> Cohttp_lwt.Body.of_string
        in
        let* response, x =
          let headers =
            Cohttp.Header.init_with "content-type" "application/json"
          in
          Cohttp_lwt_unix.Client.post ~headers ~body (Uri.of_string url)
        in
        let* hint = Cohttp_lwt.Body.to_string x in
        match Cohttp.Code.code_of_status response.status with
        | 200 -> (
            match Yojson.Safe.from_string hint with
            | `String hint -> Lwt.return_ok hint
            | _ | (exception _) -> Lwt.return_error ())
        | _ -> Lwt.return_error ())
  in
  let* reason, admin_id, uuid, { recipient; subject; body } =
    match msg with
    | `Account_create { lang; recipient; code; uuid; _ } ->
        let lang = Language.get lang in
        let* l = Web_i18n.get ~component:"admin" ~lang in
        let t = Mails_admin.mail_confirmation_link l ~recipient ~code in
        Lwt.return ("account-creation", "", uuid, t)
    | `Account_change_password { lang; recipient; code; uuid; _ } ->
        let lang = Language.get lang in
        let* l = Web_i18n.get ~component:"admin" ~lang in
        let t = Mails_admin.mail_changepw_link l ~recipient ~code in
        Lwt.return ("password-change", "", uuid, t)
    | `Account_set_email { lang; recipient; code; uuid; _ } ->
        let lang = Language.get lang in
        let* l = Web_i18n.get ~component:"admin" ~lang in
        let t = Mails_admin.mail_set_email l ~recipient ~code in
        Lwt.return ("set-email", "", uuid, t)
    | `Voter_password x ->
        let* t = Mails_voter.format_password_email x in
        let m = Option.value ~default:dummy_metadata x.metadata in
        Lwt.return ("password", string_of_int m.admin_id, Some m.uuid, t)
    | `Voter_credential x ->
        let* t = Mails_voter.format_credential_email x in
        let m = Option.value ~default:dummy_metadata x.metadata in
        Lwt.return ("credential", string_of_int m.admin_id, Some m.uuid, t)
    | `Vote_confirmation { lang; uuid; title; confirmation; contact } ->
        let lang = Language.get lang in
        let* l = Web_i18n.get ~component:"voter" ~lang in
        let t =
          Mails_voter.mail_confirmation l uuid ~title confirmation contact
        in
        Lwt.return ("confirmation", "", Some uuid, t)
    | `Mail_login { lang; recipient; state; code; uuid } ->
        let lang = Language.get lang in
        let* l = Web_i18n.get ~component:"voter" ~lang in
        let t = Mails_voter.email_login l ~recipient ?state ~code () in
        Lwt.return ("login", "", uuid, t)
    | `Credentials_seed m ->
        let lang = Language.get m.lang in
        let* l = Web_i18n.get ~component:"admin" ~lang in
        let t = Mails_admin.mail_credentials_seed l m in
        Lwt.return ("credentials-seed", string_of_int m.admin_id, Some m.uuid, t)
  in
  let@ _check_recipient cont =
    if String.contains recipient.address '@' then cont ()
    else Lwt.return_error ()
  in
  let contents =
    Netsendmail.compose
      ~from_addr:(!Web_config.server_name, !Web_config.server_mail)
      ~to_addrs:[ (recipient.name, recipient.address) ]
      ~in_charset:`Enc_utf8 ~out_charset:`Enc_utf8 ~subject body
  in
  let headers, _ = contents in
  let token = generate_token ~length:6 () in
  let date = Unix.gettimeofday () |> Float.round |> Float.to_string in
  let message_id = Printf.sprintf "<%s%s@%s>" date token !Web_config.domain in
  headers#update_field "Message-ID" message_id;
  headers#update_field "Belenios-Domain" !Web_config.domain;
  headers#update_field "Belenios-Reason" reason;
  let () =
    match uuid with
    | None -> ()
    | Some uuid -> headers#update_field "Belenios-UUID" (Uuid.unwrap uuid)
  in
  let () =
    match !Web_config.fbl_senderid with
    | None -> ()
    | Some senderid ->
        let uuid =
          match uuid with None -> "" | Some uuid -> Uuid.unwrap uuid
        in
        headers#update_field "Feedback-ID"
          (Printf.sprintf "%s:%s:%s:%s" uuid admin_id reason senderid)
  in
  let sendmail_func = fun () -> sendmail ~uuid ~recipient:recipient.address contents in
  let rec loop retry =
    Lwt.catch
      (fun () ->
        let* () = Lwt_preemptive.detach sendmail_func () in
        Ocsigen_messages.errlog ("SMTP: Successfully sent email to " ^ recipient.address);
        Lwt.return_ok recipient.address)
      (function
        | Unix.Unix_error (Unix.EAGAIN, _, _) when retry > 0 ->
            Ocsigen_messages.warning
              "Failed to send an e-mail; will try again in 1s";
            let* () = sleep 1. in
            loop (retry - 1)
        | e ->
            let msg =
              Printf.sprintf "Failed to send an e-mail to %s: %s"
                recipient.address (Printexc.to_string e)
            in
            Ocsigen_messages.errlog msg;
            Lwt.return_error ())
  in
  loop 2

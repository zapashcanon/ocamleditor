(*

  OCamlEditor
  Copyright (C) 2010-2014 Francesco Tovagliari

  This file is part of OCamlEditor.

  OCamlEditor is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  OCamlEditor is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program. If not, see <http://www.gnu.org/licenses/>.

*)


open Preferences
open Printf

type icon = P of GdkPixbuf.pixbuf | S of GtkStock.id | N

type kind = B | BM | M | I

type 'a item = {
  id                         : int;
  tag                        : 'a;
  kind                       : kind;
  pixbuf                     : icon;
  label                      : string;
  check                      : GMenu.check_menu_item;
  mutable tool_widget        : GObj.widget option;
  mutable tool_callback      : (unit -> unit);
  mutable tool_callback_menu : (string option ref * GMenu.menu -> unit) option;
}

let pixbuf_empty =
  let pixbuf = GdkPixbuf.create ~width:1 ~height:16 ~has_alpha:true () in
  GdkPixbuf.fill pixbuf 0l;
  let pixbuf = GdkPixbuf.add_alpha ~transparent:(0,0,0) pixbuf in
  pixbuf

(** specs *)
let specs ~browser =
  let editor : Editor.editor = browser#editor in [
    100,  `NEW_FILE,       B, P Icons.new_file, "New File...",
    (fun _ -> browser#dialog_file_new()),
    None;

    200,  `OPEN_FILE,      B, P Icons.open_file, "Open File...",
    (fun _ -> editor#dialog_file_open ()),
    None;

    300,  `SAVE,           B, P Icons.save_16, "Save",
    (fun _ -> Gaux.may ~f:editor#save (editor#get_page `ACTIVE)),
    None;

    400,  `SAVE_ALL,       B, P Icons.save_all_16, "Save All",
    (fun _ -> browser#save_all ()),
    None;

    500,  `CLOSE,          B, S `CLOSE, "Close Current File",
    (fun _ -> editor#with_current_page (fun p -> ignore (editor#dialog_confirm_close p))),
    None;

    600,  `SEP,            I, N, "", ignore, None;

    700,  `FIND_REPL,      B, P Icons.find_replace, "Find and Replace", begin fun _ ->
      Menu_search.find_replace ?find_all:None ?search_word_at_cursor:None editor
    end, None;

    800,  `SEARCH_AGAIN,   B, P Icons.search_again_16, "Search Again",
    (fun _ -> Menu_search.search_again editor),
    None;

    900,  `SEP,            I, N, "", ignore, None;

    1000, `VIEW_MESSAGES,  B, P Icons.paned_bottom, "View Messages",
    (fun _ -> browser#set_vmessages_visible (not Messages.vmessages#visible)),
    None;

    1100, `VIEW_HMESSAGES, B, P Icons.paned_right, "View Messages (Right Pane)",
    (fun _ -> browser#set_hmessages_visible (not Messages.hmessages#visible)),
    None;

    1200, `SEP,            I, N, "", ignore, None;

    1300, `EVAL_TOPLEVEL,  B, P Icons.toplevel, "Eval in Toplevel",
    (fun _ -> editor#with_current_page (fun page -> page#ocaml_view#obuffer#send_to_shell ())),
    None;

    1400, `COMPILE_FILE,   B, P Icons.compile_file_16, "Compile Current File", begin fun _ ->
      browser#editor#with_current_page begin fun p ->
        if Preferences.preferences#get.Preferences.pref_editor_save_all_bef_comp then (editor#save_all());
        p#compile_buffer ?join:None ()
      end
    end, None;

    1500, `SEP,            I, N, "", ignore, None;

    1600, `SHOW_TARGETS,   B, P Icons.target_16, "Targets", begin fun _ ->
      browser#dialog_project_properties ?page_num:(Some 1) ?show:(Some true) ()
    end, None;

    1700, `SEP,            I, N, "", ignore, None;

    1750, `CLEAN_PROJ,     B, N, "Clean Project",
    browser#project_clean,
    None;

    1800, `CLEAN,          BM, P Icons.clear_build_16, "Clean...",
    (fun () -> browser#toolbar#clean_current browser),
    Some (browser#toolbar#clean_menu browser);

    1900, `COMPILE,        BM, P Icons.compile_all_16, "Compile...",
    (fun () -> browser#toolbar#compile_current browser),
    Some (browser#toolbar#compile_menu browser);

    2000, `BUILD,          BM, P Icons.build_16, "Build...",
    (fun () -> browser#toolbar#build_current browser),
    Some (browser#toolbar#build_menu browser);

    2100, `BUILD_DEP,      M, N, "Build Dep.",
    begin fun () ->
      browser#with_current_project begin fun project ->
        browser#with_default_target begin fun target ->
          ignore (Task_console.exec ~editor ~with_deps:true `COMPILE target)
        end
      end
    end,
    Some (begin fun (label, menu) ->
        browser#with_current_project begin fun project ->
          browser#with_default_target begin fun target ->
            label := None;
          end;
          List.iter begin fun tg ->
            let item = GMenu.menu_item ~label:tg.Target.name ~packing:menu#add () in
            ignore (item#connect#activate ~callback:begin fun () ->
                ignore (Task_console.exec ~editor ~with_deps:true `COMPILE tg)
              end);
          end project.Prj.targets;
        end
      end);

    2200, `RUN,            BM, P Icons.start_16, "Run...",
    (fun () -> browser#toolbar#run_current browser),
    Some (browser#toolbar#run_menu browser);
  ]

(** items *)
let items ~browser =
  let items =
    List.map (fun (id, tag, kind, pixbuf, label, tool_callback, tool_callback_menu) -> {
          id;
          tag;
          kind;
          pixbuf;
          label;
          check       = GMenu.check_menu_item ~active:false ();
          tool_widget = None;
          tool_callback;
          tool_callback_menu;
        }) (specs ~browser)
  in
  items, fun tag ->
    try
      let item = List.find (fun it -> it.tag = tag) items in
      item.tool_widget
    with Not_found -> assert false

(** create_tool *)
let create_tool ~(toolbox : GPack.box) item =
  let image =
    match item.pixbuf with
    | P _ when item.tag = `VIEW_MESSAGES -> Some (GMisc.image ~pixbuf:Icons.paned_bottom_large ())
    | P pixbuf -> Some (GMisc.image ~pixbuf ())
    | S stock -> Some (GMisc.image ~stock ~icon_size:`SMALL_TOOLBAR ())
    | N -> None
  in
  match item.kind with
  | I -> (GMisc.separator `VERTICAL ~packing:toolbox#pack ())#coerce
  | BM ->
      let tool = Gmisclib.Button.button_menu ~relief:`NONE ~spacing:1 ~packing:toolbox#pack () in
      Gaux.may image ~f:(fun image -> tool#set_image image#coerce);
      tool#button#misc#set_name "menubar_button";
      tool#button_menu#misc#set_name "menubar_button_arrow";
      tool#button#set_focus_on_click false;
      tool#button#misc#modify_fg [`PRELIGHT, `BLACK];
      tool#button_menu#misc#modify_fg [`PRELIGHT, `BLACK];
      tool#connect#clicked ~callback:(fun () -> Gmisclib.Idle.add item.tool_callback) |> ignore;
      Gaux.may item.tool_callback_menu ~f:(fun callback -> tool#connect#show_menu ~callback) |> ignore;
      tool#coerce
  | M ->
      let tool = Gmisclib.Button.button_menu ~label:item.label ~relief:`NONE ~packing:toolbox#pack () in
      Gaux.may image ~f:(fun image -> tool#set_image image#coerce);
      tool#button#misc#set_name "menubar_button";
      tool#button_menu#misc#set_name "menubar_button";
      tool#button#set_focus_on_click false;
      tool#set_menu_only();
      tool#connect#clicked ~callback:(fun () -> Gmisclib.Idle.add item.tool_callback) |> ignore;
      Gaux.may item.tool_callback_menu ~f:(fun callback -> tool#connect#show_menu ~callback) |> ignore;
      tool#coerce
  | B ->
      let button = GButton.button ~relief:`NONE ~packing:toolbox#pack () in
      begin
        match image with
        | Some image -> button#set_image image#coerce
        | _ -> button#set_label item.label
      end;
      button#misc#set_name "menubar_button";
      button#set_focus_on_click false;
      button#child#misc#modify_fg [`PRELIGHT, `BLACK];
      let callback = fun () -> Gmisclib.Idle.add item.tool_callback in
      button#connect#clicked ~callback |> ignore;
      button#coerce
;;

(** create_item *)
let create_item ~menu ~(toolbox : GPack.box) ~pos item =
  menu#add (item.check :> GMenu.menu_item);
  item.check#event#connect#button_release ~callback:begin fun _ ->
    item.check#set_active (not item.check#active);
    true;
  end |> ignore;
  item.check#connect#toggled ~callback:begin fun () ->
    let add_pref () =
      preferences#get.pref_general_menubar_buttons <-
        item.id :: (List.filter ((<>) item.id) preferences#get.pref_general_menubar_buttons);
    in
    match item.check#active with
    | true when item.tool_widget <> None ->
        Gaux.may item.tool_widget ~f:(fun w -> w#misc#show());
        add_pref();
    | true -> assert false
    | false ->
        Gaux.may item.tool_widget ~f:(fun w -> w#misc#hide());
        preferences#get.pref_general_menubar_buttons <- List.filter ((<>) item.id) preferences#get.pref_general_menubar_buttons;
  end |> ignore;
  let box = GPack.hbox ~packing:item.check#add () in
  let text, image =
    match item.pixbuf with
    | P pixbuf -> item.label, GMisc.image ~pixbuf ~xpad:8 ~packing:box#pack ()
    | S stock -> item.label, GMisc.image ~stock ~icon_size:`SMALL_TOOLBAR ~xpad:8 ~packing:box#pack ()
    | N when item.kind = I ->
        let image = GMisc.image ~pixbuf:pixbuf_empty ~packing:box#pack ~xpad:3 () in
        let _ = GMisc.separator `HORIZONTAL ~packing:box#add () in
        "", image
    | N ->
        let image = GMisc.image ~pixbuf:pixbuf_empty ~packing:box#pack ~xpad:3 () in
        item.label, image
  in
  let _ = GMisc.label ~text ~xalign:0.0 ~packing:box#add () in
  item.tool_widget <- Some (create_tool ~toolbox item);
  let active = List.mem item.id preferences#get.pref_general_menubar_buttons in
  item.check#set_active (not active);
  item.check#set_active active;
;;

(** populate *)
let populate ~browser ~packing =
  let toolbox = GPack.hbox ~border_width:2 ~spacing:3 ~packing () in
  let button_menu = GButton.button ~relief:`NONE ~packing:toolbox#pack () in
  button_menu#misc#set_name "smallbutton";
  button_menu#set_focus_on_click false;
  let arrow = GMisc.arrow ~kind:`DOWN ~width:8 ~height:8 ~packing:button_menu#add () in
  arrow#misc#modify_fg [`PRELIGHT, `BLACK];
  let menu = GMenu.menu ~border_width:3 () in
  let items, find = items ~browser in
  List.iteri (fun pos item -> create_item ~menu ~toolbox ~pos:(pos + 2) item) items;
  button_menu#event#connect#button_press ~callback:begin fun ev ->
    let time = GdkEvent.Button.time ev in
    let pos ~x ~y ~pushed_in =
      let xP, yP = Gdk.Window.get_pointer_location button_menu#misc#window in
      let xA, yA = button_menu#misc#allocation.Gtk.x, button_menu#misc#allocation.Gtk.y in
      let x' = x - xP + xA in
      let y' = y - yP + yA + button_menu#misc#allocation.Gtk.height in
      x', y', pushed_in
    in
    GtkMenu.Menu.popup_at menu#as_menu ~time ~button:1 pos;
    Gmisclib.Idle.add ~prio:300 begin fun () ->
      Gdk.Window.set_cursor menu#misc#window (Gdk.Cursor.create `ARROW)
    end;
    false;
  end |> ignore;
  let cursor = Gdk.Cursor.create `ARROW in
  button_menu#event#connect#motion_notify  ~callback:begin fun _ ->
    Gdk.Window.set_cursor button_menu#misc#window cursor;
    false;
  end |> ignore;
  menu#event#connect#motion_notify  ~callback:begin fun _ ->
    Gdk.Window.set_cursor menu#misc#window cursor;
    false;
  end |> ignore;
  menu#connect#deactivate ~callback:Preferences.save |> ignore;
  find









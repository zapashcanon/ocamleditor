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

open Printf

type hover = Out | Mark of (int * int * bool) | Region
type tag_table_kind = Hidden
type tag_table_entry = {
  mark_start_fold : GText.mark;
  mark_stop_fold  : GText.mark;
  tag             : GText.tag;
}

type fold_iters = {
  fit_start_marker : GText.iter;
  fit_start_fold : GText.iter;
  fit_stop : GText.iter;
}

let fold_size = 11 (*10 *)
let dx = 5 (*4*)
let dx1 = dx - 1
let dx12 = (dx - 1) / 2
let dxdx12 = dx - dx12

let split_length num =
  let rec f acc parts fact = function
    | 0 -> acc
    | 1 -> 1 :: acc
    | n when parts = 1 -> n :: acc
    | n ->
        let sect = int_of_float ((float n) *. fact) in
        let sect = if sect = 0 && parts > 1 then (n - sect) else sect in
        sect :: (f acc (parts - 1) fact (n - sect))
  in
  let parts = min 5 num in
  f [] parts 0.62 num;;

class manager ~(view : Text.view) =
  (*let explicit = false in*)
  let min_length = 3 in
  let buffer = view#buffer in
  let set_highlight_background tag = Gmisclib.Util.set_tag_paragraph_background tag in
  object (self)
    val mutable enabled = true;
    val mutable folding_points = []
    val mutable graphics = []
    val mutable markers = []
    val mutable tag_highlight_applied = None
    val mutable tag_highlight_busy = false
    val mutable table_tag_hidden : tag_table_entry list = []
    val mutable signal_expose = None
    val mutable tag_highlight = buffer#create_tag
        ~name:(sprintf "tag_code_folding_focus_%f" (Unix.gettimeofday())) []
    val toggled = new toggled ()
    val mutable fold_line_color = `NAME "#000000"
    val mutable light_marker_color = `NAME "#000000"

    method enabled = enabled
    method set_enabled x =
      enabled <- x;
      if enabled then begin
        view#gutter.Gutter.fold_size <- fold_size;
        Gmisclib.Idle.add view#draw_gutter;
        self#scan_folding_points();
      end else begin
        self#expand_all();
        view#gutter.Gutter.fold_size <- 0;
        folding_points <- [];
        Gmisclib.Idle.add view#draw_gutter;
      end;

    method fold_line_color = fold_line_color
    method set_fold_line_color x =
      fold_line_color <- x

    method scan_folding_points () =
      if enabled then begin
        Gmisclib.Idle.add (*~prio:300*) begin fun () ->
          let vrect = view#visible_rect in
          let h0 = Gdk.Rectangle.height vrect in
          let y0 = Gdk.Rectangle.y vrect in
          let start, _ = view#get_line_at_y y0 in
          let stop, _ = view#get_line_at_y (y0 + h0) in
          (* Find all comments in the buffer *)
          let comments =
            let text = buffer#get_text () in
            GtkThread2.sync Comments.scan_locale (Glib.Convert.convert_with_fallback ~fallback:""
                                                    ~from_codeset:"UTF-8" ~to_codeset:Oe_config.ocaml_codeset text)
          in
          (* Adjust start and stop positions *)
          let start = start#backward_line#set_line_index 0 in
          let stop = stop#forward_line#set_line_index 0 in
          let text = buffer#get_text ~start ~stop () in
          (* Find folding points in the visible text *)
          let fp, pos = GtkThread2.sync Delimiters.scan_folding_points text in
          let offset = start#offset + pos in
          (* Visible rect. to buffer offsets *)
          let fp = List.fold_left begin fun acc -> function
              | (a, -1) -> (offset + a, None) :: acc
              | (a, b) -> (offset + a, Some (offset + b)) :: acc
            end [] fp in
          (* Exclude folding points inside comments *)
          let fp = List.filter begin function
            | (a, Some b) -> ListLabels.for_all comments ~f:(fun (bc, ec, _) -> not (a >= bc && b <= ec))
            | (a, None) -> ListLabels.for_all comments ~f:(fun (bc, ec, _) -> not (a >= bc && a <= ec))
            end fp in
          (* Join folding points to comments *)
          let comments = List.map (fun (a, b, _) -> (a, Some b)) comments in
          let fp = List.sort (fun (a, _) (b, _) -> Stdlib.compare a b) (fp @ comments) in
          folding_points <- fp;
        end
      end

    method is_folded (i1 : GText.iter) =
      List.exists (fun {tag=t; _} -> i1#has_tag t) table_tag_hidden

    method private is_hover x y =
      try
        let xs = view#gutter.Gutter.fold_x in
        let ms =
          try
            let _, _, ms = 
              graphics |> List.find begin fun (y1, y2, _) ->
                x >= xs && x <= view#gutter.Gutter.size && y1 <= y && y <= y2
              end 
            in
            ms
          with Not_found -> (raise Exit)
        in
       	let unmatched, (yb1, yb2, yv1, h1), _ = ms in
        if yv1 <= y && y <= yv1 + h1 then Mark (yb1, yb2, unmatched)
        else Out
      with Exit -> Region

    method private get_folding_iters of1 of2 =
      let start_folding_point = buffer#get_iter (`OFFSET of1) in
      let stop = (buffer#get_iter (`OFFSET of2))#set_line_index 0 in
      {
        fit_start_marker = start_folding_point#set_line_index 0;
        fit_start_fold = start_folding_point#forward_line#set_line_index 0;
        fit_stop = stop;
      }

    method private draw_line y =
      match view#get_window `TEXT with
      | Some window ->
          let drawable = new GDraw.drawable window in
          let vrect = view#visible_rect in
          let width = 2 in
          let y0 = Gdk.Rectangle.y vrect in
          let w0 = Gdk.Rectangle.width vrect in
          let offset = match Oe_config.dash_style_offset with Some x -> x | _ -> w0 in
          let y = y - y0 + width / 2 in
          drawable#set_foreground fold_line_color;
          Gdk.GC.set_fill drawable#gc `SOLID;
          Gdk.GC.set_dashes drawable#gc ~offset [2; 2];
          drawable#set_line_attributes ~width ~style:Oe_config.dash_style ();
          drawable#line ~x:0 ~y ~x:w0 ~y;
      | _ -> ()

    method private draw_markers () =
      match view#get_window `LEFT with
      | Some window ->
          let xs = view#gutter.Gutter.fold_x in
          let xm = xs + view#gutter.Gutter.fold_size / 2 in (* center of the fold part *)
          let folds = ref [] in
          let vrect = view#visible_rect in
          let y0 = Gdk.Rectangle.y vrect in
          (* Filter folding_points by visible area *)
          let h0 = Gdk.Rectangle.height vrect in
          let bottom, _ = view#get_line_at_y (y0 + h0) in
          (* Filter folding_points to be drawn *)
          let draw_line_at_iter iter =
            let y, h = view#get_line_yrange iter in
            self#draw_line (y + h);
          in
          folding_points (*exposed*) |> List.iter begin function
          | (of1, Some of2) ->
              let fi = self#get_folding_iters of1 of2 in
              let i1 = buffer#get_iter (`OFFSET of1) in
              let i2 = buffer#get_iter (`OFFSET of2) in
              let i2 = i2#forward_line in
              if fi.fit_stop#line - fi.fit_start_marker#line > min_length then begin
                if not (self#is_folded i1#backward_char) then begin
                  let is_collapsed = self#is_folded fi.fit_start_fold in
                  if is_collapsed then draw_line_at_iter fi.fit_start_marker;
                  let yb1, h1 = view#get_line_yrange fi.fit_start_marker in
                  let yb2, h2 = view#get_line_yrange i2 in
                  let yv1 = yb1 - y0 in
                  let yv2 = yb2 - y0 in
                  let ym1 = yv1 + h1/2 - 1 in
                  let ym2 = yv2 - h2 + h2/2 + 3 in
                  let ys1 = yv1 in
                  let ys2 = yv2 + 1 in
                  let of2 = i2#offset in
                  let ms = false, (of1, of2, yv1, h1), (is_collapsed, ym1) in
                  folds := ((fi.fit_start_marker#line, i2#line, is_collapsed), ys1, ys2, ms) :: !folds
                end
              end;
          | (of1, None) ->
              let i1 = buffer#get_iter (`OFFSET of1) in
              if not (self#is_folded i1#backward_char) then begin
                let is_collapsed = self#is_folded (if i1#ends_line then i1 else i1#forward_to_line_end) in
               	if is_collapsed then draw_line_at_iter i1;
                let yb1, h1 = view#get_line_yrange i1 in
                let yb2, h2 = view#get_line_yrange bottom in
                let yv1 = yb1 - y0 in
                let yv2 = yb2 - y0 in
                let ym1 = yv1 + h1/2 - 1 in
                let ys1 = yv1 in
                let ys2 = yv2 + 1 in
                let ms = true, (of1, bottom#offset, yv1, h1), (is_collapsed, ym1) in
                folds := ((i1#line, -1, is_collapsed), ys1, ys2, ms) :: !folds
              end
          end;
          (* Draw lines and markers in the same iter (to reduce flickering?) *)
          let drawable = new GDraw.drawable window in
          drawable#set_foreground view#gutter.Gutter.marker_color;
          drawable#set_line_attributes ~width:2 ~cap:`PROJECTING ~style:`SOLID ();
          Gdk.GC.set_dashes drawable#gc ~offset:1 [1; 2];
          let folds = 
            !folds |> List.fold_left begin fun acc ((_, l2, _) as ll, a, b, ms) ->
              match acc with
              | ((l1', _, is_collapsed), _, _, _) :: _ when l2 = l1' + 1 -> 
                  (ll, a, b, ms) :: acc
              | _ -> 
                  (ll, a, b, ms) :: acc
            end [] 
            |> List.rev 
          in
          folds |> List.iter begin fun (_, _, _, ms) ->
            (* Markers *)
            let unmatched, _, (is_collapsed, ym1) = ms in
            let xm = xm - 3 in
            let ym1 = ym1 - dx in
            let ya = ym1 + 2*dx in
            let square = [(xm - dx, ym1); (xm + dx, ym1); (xm + dx, ya); (xm - dx, ya)] in
            if is_collapsed then begin
              drawable#set_foreground view#gutter.Gutter.marker_bg_color;
              drawable#polygon ~filled:true square;
              drawable#set_foreground view#gutter.Gutter.marker_color;
              drawable#polygon ~filled:false square;
              drawable#segments [(xm, ym1 + dx12 + 1), (xm, ym1 + dx1*2 - 1); (xm - dxdx12 + 1, ym1 + dx), (xm + dxdx12 - 1, ym1 + dx)];
            end else begin
              drawable#set_foreground view#gutter.Gutter.bg_color;
              if unmatched then begin
                drawable#set_foreground view#gutter.Gutter.bg_color;
                drawable#polygon ~filled:true square;
                drawable#set_foreground light_marker_color;
                drawable#polygon ~filled:false square;
              end else begin
                drawable#polygon ~filled:true square;
                drawable#set_foreground view#gutter.Gutter.marker_color;
                drawable#polygon ~filled:false square;
              end;
              drawable#segments [(xm - dxdx12 + 1, ym1 + dx), (xm + dxdx12 - 1, ym1 + dx)];
            end;
          end;
          graphics <- folds |> List.map (fun (_, a, b, ms) -> a, b, ms);
      | _ -> ()

    method private range ~fold start stop =
      let iter = ref start in
      let stop = stop#set_line_index 0 in
      while not (!iter#equal stop) do
        begin
          match List_opt.find (fun {tag=t; _} -> !iter#has_tag t) table_tag_hidden with
          | Some entry -> entry.tag#set_properties [`INVISIBLE fold; `INVISIBLE_SET fold]
          | _ -> ()
        end;
        iter := !iter#forward_line
      done;

    method private fold_offsets o1 o2 =
      let fi = self#get_folding_iters o1 o2 in
      let start = fi.fit_start_fold in
      let stop = fi.fit_stop in
      if stop#line - fi.fit_start_marker#line >= min_length then begin
        match self#remove_tag_from_table Hidden start with
        | None ->
            view#matching_delim_remove_tag ();
            let ins = buffer#get_iter `INSERT in
            let is_in_range = ins#in_range ~start ~stop in
            Gaux.may view#signal_expose ~f:(fun id -> view#misc#handler_block id);
            view#matching_delim_remove_tag ();
            self#range ~fold:false start stop;
            let tag_hidden = buffer#create_tag [`INVISIBLE_SET true; `INVISIBLE true(*; `EDITABLE false*)] in
            let m1 = `MARK (buffer#create_mark(* ~name:(Gtk_util.create_mark_name "Code_folding.fold_offset1")*) start) in
            let m2 = `MARK (buffer#create_mark(* ~name:(Gtk_util.create_mark_name "Code_folding.fold_offset2")*) stop) in
            (*Gmisclib.Util.set_tag_paragraph_background tag_readonly "yellow" (*Oe_config.code_folding_highlight_color*);*)
            buffer#apply_tag tag_hidden ~start ~stop;
            table_tag_hidden <- {mark_start_fold=m1; mark_stop_fold=m2; tag=tag_hidden} :: table_tag_hidden;
            self#scan_folding_points();
            self#highlight_remove ();
            Gmisclib.Idle.add view#draw_gutter;
            if is_in_range then
              Gmisclib.Idle.add begin fun () ->
                let where = fi.fit_start_marker#forward_to_line_end in
                view#buffer#place_cursor ~where;
                view#scroll_lazy where;
              end;
            Gaux.may view#signal_expose ~f:(fun id -> view#misc#handler_unblock id);
            toggled#call (true, start, stop);
        | Some {mark_start_fold=m1; mark_stop_fold=m2; tag=tag; _} ->
            self#range ~fold:true start stop;
            let iter = ref start in
            let n = stop#line - start#line in
            let sections = List.rev (split_length n) in
            Gaux.may view#signal_expose ~f:(fun id -> view#misc#handler_block id);
            Gaux.may signal_expose ~f:(fun id -> view#misc#handler_block id);
            Gmisclib.Idle.add_gen begin 
              let i = ref (List.length sections - 1) in 
              fun () ->
                try
                  if !i > 0 && !iter#compare stop < 0 then begin
                    let lines = max 3 (List.nth sections !i) in
                    iter := !iter#forward_lines lines;
                    buffer#remove_tag tag ~start ~stop:!iter;
                    decr i;
                    true
                  end else begin
                    buffer#remove_tag tag ~start ~stop;
                    Gmisclib.Idle.add ~prio:100 view#draw_gutter;
                    Gaux.may view#signal_expose ~f:(fun id -> view#misc#handler_unblock id);
                    Gaux.may signal_expose ~f:(fun id -> view#misc#handler_unblock id);
                    false
                  end;
                with ex -> (eprintf "%s\n%!" (Printexc.to_string ex); false)
            end |> ignore;
            Gmisclib.Idle.add ~prio:300 begin fun () ->
              buffer#delete_mark m1;
              buffer#delete_mark m2;
            end;
            toggled#call (false, start, stop);
      end;

    method private fold (_ : Gdk.window) x y =
      try
        begin
          match self#is_hover x y with
          | Mark (o1, o2, unmatched) ->
              let o2 = if unmatched then begin
                  match self#find_matching_delimiter o1 with
                  | Some iter -> iter#forward_to_line_end#forward_char#offset
                  | _ -> raise Exit
                end else o2 in
              self#fold_offsets o1 o2;
              true
          | Region -> false
          | Out -> true
        end;
      with Exit -> true

    method private find_matching_delimiter o1 =
      let iter = (buffer#get_iter (`OFFSET o1))#backward_word_start in
      let text = buffer#get_text ~start:iter ~stop:buffer#end_iter () in
      match Delimiters.find_closing_folding_point text with
      | Some stop ->
          let stop = stop + iter#offset in
          Some (buffer#get_iter (`OFFSET stop))
      | _ -> None

    method private remove_tag_from_table which_table iter =
      let tag_table = match which_table with Hidden -> table_tag_hidden in
      let res, tab =
        List.fold_left begin fun (res, acc) ({tag=t; _} as entry) ->
          if res = None && iter#has_tag t then (Some entry, acc) else (res, entry :: acc)
        end (None, []) tag_table
      in
      (match which_table with Hidden -> table_tag_hidden <- tab);
      res

    method toggle_current_fold () =
      let iter = buffer#get_iter `INSERT in
      let i = iter#forward_to_line_end#offset in
      let points = List.filter begin function
        | (a, Some b) -> a <= i && i <= b
        | _ -> false
        end folding_points in
      let points = List.sort (fun (a1, _) (a2, _) -> Stdlib.compare a2 a1) points in
      match points with
      | (o1, Some o2) :: _ -> self#fold_offsets o1 o2
      | _ -> ()

    method expand_current () = self#expand (buffer#get_iter `INSERT)#forward_to_line_end

    method expand (iter : GText.iter) =
      let tags_owned_by_iter ~which_table =
        let tags = List.filter (fun {tag=tag; _} -> iter#has_tag tag) which_table in
        List.sort begin fun {mark_start_fold=ma; _} {mark_start_fold=mb; _} ->
          let ia = buffer#get_iter_at_mark ma in
          let ib = buffer#get_iter_at_mark mb in
          ia#compare ib
        end tags
      in
      (*  *)
      let tags = tags_owned_by_iter ~which_table:table_tag_hidden in
      List.iter begin fun {mark_start_fold=m1; mark_stop_fold=m2; tag=tag; _} ->
        let start = buffer#get_iter_at_mark m1 in
        let stop = buffer#get_iter_at_mark m2 in
        buffer#remove_tag tag ~start ~stop;
        self#range ~fold:true start stop; (* re-collapse folds inside the expanded fold, if they were folded *)
        buffer#delete_mark m1;
        buffer#delete_mark m2;
        table_tag_hidden <- List.filter (fun x -> x.mark_start_fold != m1) table_tag_hidden;
      end tags;
      if List.length tags > 0 then (Gmisclib.Idle.add view#draw_gutter);

    method expand_all () =
      List.iter begin fun {mark_start_fold=m1; mark_stop_fold=m2; tag=tag; _} ->
        let start = buffer#get_iter_at_mark m1 in
        let stop = buffer#get_iter_at_mark m2 in
        buffer#remove_tag tag ~start ~stop;
      end table_tag_hidden;
      table_tag_hidden <- [];
      Gmisclib.Idle.add view#draw_gutter

    method private highlight x y =
      match view#get_window `LEFT with
      | Some window ->
          self#draw_markers();
          begin
            match self#is_hover x y with
            | Mark (o1, o2, unmatched) as mark ->
                if not tag_highlight_busy && tag_highlight_applied = None then begin
                  try
                    let fi = self#get_folding_iters o1 o2 in
                    if self#is_folded fi.fit_start_fold then raise Exit;
                    set_highlight_background tag_highlight Oe_config.code_folding_highlight_color;
                    let start = (buffer#get_iter (`OFFSET o1))#set_line_index 0 in
                    let stop =
                      if unmatched then begin
                        match self#find_matching_delimiter o1 with
                        | Some iter -> iter#forward_to_line_end#forward_char
                        | _ -> raise Exit
                      end else ((buffer#get_iter (`OFFSET o2))#set_line_index 0)
                    in
                    buffer#apply_tag tag_highlight ~start ~stop;
                    tag_highlight_applied <- Some mark;
                  with Exit -> ()
                end else begin
                  match tag_highlight_applied with
                  | None -> ()
                  | Some m when m = mark -> ()
                  | _ -> self#highlight_remove ();
                end;
            | Region
            | Out -> self#highlight_remove ()
          end
      | _ -> ()

    method private highlight_remove () =
      if tag_highlight_applied <> None && not tag_highlight_busy then begin
        tag_highlight_busy <- true;
        let grad = Oe_config.code_folding_hightlight_gradient in
        if grad = [] then begin
          buffer#remove_tag tag_highlight ~start:buffer#start_iter ~stop:buffer#end_iter;
          tag_highlight_applied <- None;
          tag_highlight_busy <- false;
        end else begin
          ignore (GMain.Timeout.add ~ms:20 ~callback:begin let i = ref 0 in fun () ->
              tag_highlight_busy <- true;
              if !i = (List.length grad - 1) then begin
                buffer#remove_tag tag_highlight ~start:buffer#start_iter ~stop:buffer#end_iter;
                tag_highlight_applied <- None;
                tag_highlight_busy <- false;
                false
              end else begin
                (*tag_highlight_applied <- true;*)
                let color = List.nth grad !i in
                set_highlight_background tag_highlight color;
                incr i;
                true
              end
            end);
        end
      end;

    method private init () =
      signal_expose <- Some (view#event#connect#after#expose ~callback:begin fun _ ->
          if enabled then (self#draw_markers ());
          false
        end);
      ignore (view#connect#set_scroll_adjustments ~callback:begin fun _ vertical ->
          match vertical with
          | Some vertical ->
              ignore (vertical#connect#value_changed ~callback:begin fun () ->
                  Gaux.may signal_expose ~f:(fun id -> view#misc#handler_block id);
                end);
              ignore (vertical#connect#after#value_changed ~callback:(fun () ->
                  Gmisclib.Idle.add ~prio:300 self#scan_folding_points;
                  Gmisclib.Idle.add ~prio:100 (fun () ->
                      Gaux.may signal_expose ~f:(fun id -> view#misc#handler_unblock id))));
          | _ -> ()
        end);
      ignore (view#event#connect#after#button_release ~callback:begin fun ev ->
          if enabled then begin
            let window = GdkEvent.get_window ev in
            match view#get_window `LEFT with
            | Some w when (Gobject.get_oid w) = (Gobject.get_oid window) ->
                let x = GdkEvent.Button.x ev in
                let y = GdkEvent.Button.y ev in
                Gaux.may signal_expose ~f:(fun id -> view#misc#handler_block id);
                let handled = self#fold window (int_of_float x) (int_of_float y) in
                Gaux.may signal_expose ~f:(fun id -> view#misc#handler_unblock id);
                handled;
            | _ -> false
          end else false
        end);
      ignore (view#misc#connect#query_tooltip ~callback:begin fun ~x ~y ~kbd:_ _ ->
          if enabled then (self#highlight x y);
          false
        end);

      view#misc#connect#after#realize ~callback:begin fun () ->
        light_marker_color <-
          (let r, g, b = Color.rgb_of_gdk (GDraw.color view#gutter.Gutter.marker_color) in
           Color.hsv_of_name r g b
             (fun h s v ->
                `NAME (Color.name_of_hsv h s (v +. 0.35))));
      end |> ignore;

    initializer self#init()

    method connect = new code_folding_list_signals ~toggled

  end

and code_folding_list_signals ~toggled = object
  inherit GUtil.ml_signals [toggled#disconnect]
  method toggled = toggled#connect ~after
end

and toggled () = object inherit [bool * GText.iter * GText.iter] GUtil.signal () end
















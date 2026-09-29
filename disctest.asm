;; ==========================================================================
;; DISCTEST.ASM - Floppy disc surface tester for the Amstrad CPC
;; ==========================================================================
;;
;; Talks directly to the uPD765 floppy disc controller (CPC 664/6128, or a
;; 464 with DDI-1) and scans every track and side of a disc.  Every sector
;; found is read and shown as a coloured cell on a map of the disc:
;;
;;      columns = tracks, rows = sectors (sorted by sector ID)
;;
;; For every sector the program records the ID (C,H,R,N), the FDC status
;; (ST1/ST2), how many retries it needed and what kind of data it holds
;; (empty, filler, directory, AMSDOS file header, text, binary, CP/M system
;; track) or what kind of error it has (data CRC, ID CRC / sector not found /
;; no data mark, deleted data mark, weak sector, unformatted track).
;;
;; Nothing is ever written to the disc - the program only issues SPECIFY,
;; RECALIBRATE, SEEK, SENSE INTERRUPT STATUS, SENSE DRIVE STATUS, READ ID and
;; READ DATA commands.
;;
;; The disc format is discovered from the sector IDs on the disc itself, so
;; any format the FDC can read is supported: AMSDOS DATA / SYSTEM / IBM,
;; ParaDOS, ROMDOS, +3 and custom / copy protected layouts, on 3" and 3.5"
;; drives, 40 or 80 tracks, one or two sides.  A 40 track disc in an 80
;; track drive is detected and read with double stepping.
;;
;; Build : pasmo disctest.asm disctest.bin   (or any Maxam style assembler)
;; Run   : MEMORY &FFF : LOAD "DISCTEST.BIN" : CALL &1000
;;         or simply RUN "DISCTEST"  (see tools/mkdsk.py)
;;
;; Keys (map screen)
;;      cursor keys          move around the map (SHIFT+left/right = 10 tracks)
;;      D / ENTER / COPY     hex + ASCII dump of the selected sector
;;      L                    legend, statistics and key help
;;      ESC / M              back to the options menu
;;
;; Memory map
;;      &1000 - ....         program
;;      TABLE  (after code)  results table, 160 x 130 bytes
;;      &8000 - &9FFF        8K sector buffer (ring buffer, see fdc_read_sector)
;; ==========================================================================

	org &1000

;; --------------------------------------------------------------------------
;; Firmware jumpblock
;; --------------------------------------------------------------------------
KM_WAIT_CHAR	equ &bb06	; out: A=char
KM_READ_CHAR	equ &bb09	; out: carry set if A=char available
TXT_OUTPUT	equ &bb5a	; in: A=char (obeys control codes)
TXT_SET_CURSOR	equ &bb75	; in: H=column, L=row (1 based)
TXT_GET_CURSOR	equ &bb78	; out: H=column, L=row (1 based)
TXT_SET_PEN	equ &bb90	; in: A=pen
TXT_SET_PAPER	equ &bb96	; in: A=paper
SCR_RESET	equ &bc02	; default inks etc.
SCR_SET_OFFSET	equ &bc05	; in: HL=offset
SCR_SET_MODE	equ &bc0e	; in: A=mode (also clears the screen)
SCR_INK_ENCODE	equ &bc2c	; in: A=ink  out: A=encoded byte for current mode
SCR_SET_INK	equ &bc32	; in: A=ink, B,C=colours
SCR_SET_BORDER	equ &bc38	; in: B,C=colours

;; --------------------------------------------------------------------------
;; Hardware
;; --------------------------------------------------------------------------
FDC_MSR		equ &fb7e	; uPD765 main status register (data = &fb7f)
MOTOR_PORT	equ &fa7e	; bit 0 = drive motor on

;; --------------------------------------------------------------------------
;; Program constants
;; --------------------------------------------------------------------------
BUFFER		equ &8000	; 8K ring buffer &8000-&9FFF (see res 5,h trick)
MAXSLOT		equ 16		; sectors stored per track
SLOT_SIZE	equ 8		; C,H,R,N,ST1,ST2,CLASS,TRIES
ENTRY_SIZE	equ 130		; 2 + MAXSLOT*SLOT_SIZE
MAXTRACK	equ 80
MAXIDS		equ 40		; READ IDs collected per track before giving up

;; slot field offsets
SL_C		equ 0
SL_H		equ 1
SL_R		equ 2
SL_N		equ 3
SL_ST1		equ 4
SL_ST2		equ 5
SL_CLASS	equ 6
SL_TRIES	equ 7

;; track status (first byte of every table entry)
TS_NONE		equ 0		; not scanned
TS_OK		equ 1		; IDs found, slots valid
TS_UNFORM	equ 2		; no ID found - unformatted
TS_ERROR	equ 3		; drive not ready / seek failed / timeout

;; sector classes - the class number is also the mode 0 ink it is drawn in
CL_NONE		equ 0		; no sector in this slot (background)
CL_OTHER	equ 2		; not ready, overrun, timeout
CL_EMPTY	equ 3		; filled with &E5 (formatted, never written)
CL_FILL		equ 4		; filled with one other byte value
CL_DIR		equ 5		; CP/M / AMSDOS directory
CL_HEADER	equ 6		; AMSDOS file header (first record of a file)
CL_TEXT		equ 7		; mostly printable ASCII
CL_BINARY	equ 8		; anything else that read fine
CL_SYSTEM	equ 9		; CP/M system tracks of SYSTEM format
CL_DELETED	equ 10		; read fine but has a deleted data mark
CL_SOFT		equ 11		; failed, then read fine on a retry (weak)
CL_CRC		equ 12		; CRC error in the data field
CL_IDERR	equ 13		; ID CRC error / sector not found / no data mark
CL_UNFORM	equ 14		; unformatted track
INK_CURSOR	equ 15		; flashing cursor
INK_TEXT	equ 1

;; keys
K_UP		equ &f0
K_DOWN		equ &f1
K_LEFT		equ &f2
K_RIGHT		equ &f3
K_SUP		equ &f4
K_SDOWN		equ &f5
K_SLEFT		equ &f6
K_SRIGHT	equ &f7
K_COPY		equ &e0
K_ESC		equ &fc
K_ENTER		equ &0d

;; ==========================================================================
;; Entry point
;; ==========================================================================
start:
	ld (saved_sp),sp
	call init_inks
main_menu:
	call menu_screen		; carry set = quit
	jr c,quit
	call run_scan			; carry set = drive not ready
	jr c,main_menu
	call viewer
	jr main_menu

quit:
	call motor_off
	call SCR_RESET
	ld a,1
	call SCR_SET_MODE
	ld a,1
	call TXT_SET_PEN
	xor a
	call TXT_SET_PAPER
	ld sp,(saved_sp)
	ret

;; ==========================================================================
;; Palette
;; ==========================================================================
init_inks:
	ld hl,ink_table
	ld e,16
ii_loop:
	ld a,(hl)
	inc hl
	ld b,a
	ld c,a
	ld a,16
	sub e				; ink number 0..15
	push hl
	push de
	call SCR_SET_INK
	pop de
	pop hl
	dec e
	jr nz,ii_loop
	ld b,0
	ld c,0
	jp SCR_SET_BORDER

;; ink 15 (cursor) flashes, so it is set separately
set_cursor_ink:
	ld a,INK_CURSOR
	ld b,26
	ld c,0
	jp SCR_SET_INK

;; firmware colour numbers for inks 0..15
ink_table:
	db 0		; 0  background        black
	db 26		; 1  text              bright white
	db 16		; 2  read failure      pink
	db 9		; 3  empty (&E5)       green
	db 13		; 4  uniform filler    white (grey)
	db 24		; 5  directory         bright yellow
	db 8		; 6  AMSDOS header     bright magenta
	db 20		; 7  text              bright cyan
	db 11		; 8  binary            sky blue
	db 14		; 9  system track      pastel blue
	db 21		; 10 deleted data      lime
	db 15		; 11 weak / retried    orange
	db 6		; 12 data CRC error    bright red
	db 4		; 13 ID error          magenta
	db 1		; 14 unformatted       blue
	db 26		; 15 cursor            (flashing, see set_cursor_ink)

;; encoded screen bytes for every ink in mode 0 (filled by make_enc_tab)
make_enc_tab:
	ld hl,enc_tab
	xor a
met_loop:
	push af
	push hl
	call SCR_INK_ENCODE
	pop hl
	ld (hl),a
	inc hl
	pop af
	inc a
	cp 16
	jr nz,met_loop
	ret

;; ==========================================================================
;; Options menu (mode 1)
;; out: carry set = quit, clear = start scan
;; ==========================================================================
menu_screen:
	call motor_off
	ld a,1
	call SCR_SET_MODE
	ld hl,menu_text
	call print_str
ms_redraw:
	;; drive
	ld hl,&1905
	call TXT_SET_CURSOR
	ld a,(opt_drive)
	add a,"A"
	call TXT_OUTPUT
	;; tracks
	ld hl,&1906
	call TXT_SET_CURSOR
	ld a,(opt_tracks)
	ld hl,opt_trk_names
	call print_nth
	;; sides
	ld hl,&1907
	call TXT_SET_CURSOR
	ld a,(opt_sides)
	ld hl,opt_side_names
	call print_nth
	;; retries
	ld hl,&1908
	call TXT_SET_CURSOR
	ld a,(opt_retries)
	add a,"0"
	call TXT_OUTPUT
ms_key:
	call KM_WAIT_CHAR
	cp "1"
	jr z,ms_drive
	cp "2"
	jr z,ms_tracks
	cp "3"
	jr z,ms_sides
	cp "4"
	jr z,ms_retries
	cp K_ENTER
	jr z,ms_start
	cp " "
	jr z,ms_start
	cp K_ESC
	jr nz,ms_key
	scf
	ret
ms_start:
	and a
	ret
ms_drive:
	ld a,(opt_drive)
	xor 1
	ld (opt_drive),a
	jr ms_redraw
ms_tracks:
	ld a,(opt_tracks)
	inc a
	cp 4
	jr c,ms_t1
	xor a
ms_t1:	ld (opt_tracks),a
	jr ms_redraw
ms_sides:
	ld a,(opt_sides)
	inc a
	cp 3
	jr c,ms_s1
	xor a
ms_s1:	ld (opt_sides),a
	jp ms_redraw
ms_retries:
	ld a,(opt_retries)
	inc a
	cp 6
	jr c,ms_r1
	xor a
ms_r1:	ld (opt_retries),a
	jp ms_redraw

;; print the A'th 255 terminated string of the list at HL
print_nth:
	or a
	jr z,pn_print
	ld b,a
pn_skip:
	ld a,(hl)
	inc hl
	cp 255
	jr nz,pn_skip
	djnz pn_skip
pn_print:
	jp print_str

opt_trk_names:
	db "AUTO",255,"40  ",255,"42  ",255,"80  ",255
opt_side_names:
	db "AUTO",255,"1   ",255,"2   ",255

menu_text:
	db 15,1,31,5,1,"AMSTRAD CPC FLOPPY DISC TESTER"
	db 31,5,2,"=============================="
	db 31,3,5,15,3,"1",15,1,"  Drive ............"
	db 31,3,6,15,3,"2",15,1,"  Tracks ..........."
	db 31,3,7,15,3,"3",15,1,"  Sides ............"
	db 31,3,8,15,3,"4",15,1,"  Retries .........."
	db 31,3,10,15,3,"ENTER",15,1,"  Start scan"
	db 31,3,11,15,3,"ESC",15,1,"    Quit to BASIC"
	db 31,1,14,"Insert the disc to test, then press"
	db 31,1,15,"ENTER. The disc is only read, never"
	db 31,1,16,"written."
	db 31,1,18,"AUTO finds the format from the sector"
	db 31,1,19,"IDs: DATA, SYSTEM, IBM, ParaDOS,"
	db 31,1,20,"ROMDOS, +3, custom. 40 track discs in"
	db 31,1,21,"80 track drives are double stepped."
	db 31,1,23,"Map keys: arrows, D=dump, L=legend,"
	db 31,1,24,"ESC=menu."
	db 255

;; ==========================================================================
;; Scan the whole disc
;; out: carry set if the drive was not ready (message already shown)
;; ==========================================================================
run_scan:
	xor a
	call SCR_SET_MODE
	ld hl,0
	call SCR_SET_OFFSET
	call make_enc_tab
	call set_cursor_ink
	ld a,INK_TEXT
	call TXT_SET_PEN
	ld hl,msg_starting
	call print_str

	call fdc_start
	jr nc,rs_ready
	ld hl,msg_notready
	call print_str
	call flush_keys
	call KM_WAIT_CHAR
	call motor_off
	scf
	ret

rs_ready:
	ld hl,msg_detect
	call print_str
	call detect_format
	call clear_table
	ld hl,0
	ld (cnt_ok),hl
	ld (cnt_bad),hl
	ld (cnt_weak),hl
	xor a
	ld (cnt_unf),a
	ld (aborted),a
	call setup_layout
	call draw_screen

	xor a
	ld (scan_t),a
rs_track:
	xor a
	ld (scan_s),a
rs_side:
	call KM_READ_CHAR		; ESC stops the scan
	jr nc,rs_nokey
	cp K_ESC
	jr z,rs_abort
rs_nokey:
	call show_progress
	ld a,(scan_t)
	ld d,a
	ld a,(scan_s)
	ld e,a
	ld a,INK_CURSOR			; highlight the column being read
	call draw_column_ink
	call motor_on
	call scan_track
	call check_layout
	ld a,(scan_t)
	ld d,a
	ld a,(scan_s)
	ld e,a
	call draw_column
	call show_counts
	ld hl,scan_s
	inc (hl)
	ld a,(n_sides)
	cp (hl)
	jr nz,rs_side
	ld hl,scan_t
	inc (hl)
	ld a,(n_tracks)
	cp (hl)
	jr nz,rs_track
	ld hl,msg_complete
	jr rs_done
rs_abort:
	ld a,1
	ld (aborted),a
	ld hl,msg_stopped
rs_done:
	push hl
	call motor_off
	call clear_info
	call show_counts
	pop hl
	call print_str
	call flush_keys
	call KM_WAIT_CHAR
	and a
	ret

msg_starting:	db 31,1,1,"DISC TESTER",31,1,3,"STARTING DRIVE...",255
msg_notready:	db 31,1,5,"DRIVE NOT READY.",31,1,7,"NO DISC IN DRIVE",31,1,8,"OR NO SUCH DRIVE.",31,1,10,"PRESS A KEY",255
msg_detect:	db 31,1,4,"DETECTING FORMAT...",255
msg_complete:	db 31,1,25,"SCAN DONE-PRESS KEY",255
msg_stopped:	db 31,1,25,"STOPPED - PRESS KEY",255

;; "SCAN T00 S0 ESC=END" on the bottom line (19 chars: never print in
;; column 20 of line 25 or the screen scrolls)
show_progress:
	ld hl,msg_scan
	call print_str
	ld a,(scan_t)
	call print_dec2
	ld hl,msg_scan2
	call print_str
	ld a,(scan_s)
	add a,"0"
	call TXT_OUTPUT
	ld hl,msg_scan3
	jp print_str
msg_scan:	db 31,1,25,"SCAN T",255
msg_scan2:	db " S",255
msg_scan3:	db " ESC=END",255

;; running totals on lines 22-23
show_counts:
	ld hl,msg_cnt1
	call print_str
	ld hl,(cnt_ok)
	call print_dec5
	ld hl,msg_cnt2
	call print_str
	ld hl,(cnt_bad)
	call print_dec5
	ld hl,msg_cnt3
	call print_str
	ld hl,(cnt_weak)
	call print_dec5
	ld hl,msg_cnt4
	call print_str
	ld a,(cnt_unf)
	ld l,a
	ld h,0
	jp print_dec5
msg_cnt1:	db 31,1,22,"OK  ",255
msg_cnt2:	db " BAD  ",255
msg_cnt3:	db 31,1,23,"WEAK",255
msg_cnt4:	db " UNFMT",255

;; ==========================================================================
;; Detect the disc format, number of tracks, sides and double stepping
;; ==========================================================================
detect_format:
	xor a
	ld (scan_t),a
	ld (scan_s),a
	ld (t0_count),a
	ld (t0_minr),a
	xor a
	call seek_phys
	call collect_ids
	cp TS_OK
	ld hl,fmt_blank
	jr nz,df_found
	call sort_ids
	ld a,(idcount)
	ld (t0_count),a
	ld a,(idlist+SL_R)		; lowest sector ID on track 0
	ld (t0_minr),a
	;; look the lowest ID (and count) up in the format table
	ld hl,fmt_table
df_search:
	ld a,(hl)
	or a
	jr z,df_found			; end of table = CUSTOM entry
	ld b,a
	ld a,(t0_minr)
	cp b
	jr nz,df_next
	inc hl
	ld a,(hl)			; required sector count (0 = any)
	dec hl
	or a
	jr z,df_found
	ld b,a
	ld a,(t0_count)
	cp b
	jr z,df_found
df_next:
	ld de,FMT_SIZE
	add hl,de
	jr df_search
df_found:
	;; HL -> format entry: R, count, sys tracks, tracks, sides, name
	inc hl
	inc hl
	ld a,(hl)
	ld (fmt_sys),a
	inc hl
	ld a,(hl)
	ld (fmt_tracks),a
	inc hl
	ld a,(hl)
	ld (fmt_sides),a
	inc hl
	ld (fmt_name),hl

	;; double step?  Seek to physical track 2 and look at the cylinder
	;; number in the IDs: 1 means a 40 track disc in an 80 track drive.
	ld a,1
	ld (dstep),a
	ld a,(opt_tracks)
	cp 3				; forced 80 tracks: never double step
	jr z,df_nodst
	ld a,2
	call seek_phys
	jr c,df_nodst
	xor a
	call fdc_read_id
	jr c,df_nodst
	ld a,(res_buf)
	and &c0
	jr nz,df_nodst
	ld a,(res_buf+3)
	cp 1
	jr nz,df_nodst
	ld a,2
	ld (dstep),a
df_nodst:
	;; sides
	ld a,(opt_sides)
	or a
	jr nz,df_sides
	ld a,(fmt_sides)
	or a
	jr nz,df_sides
	;; probe head 1: a real second side has IDs with H=1.  A single
	;; headed drive ignores the head select and shows H=0 IDs again.
	xor a
	call seek_phys
	ld a,1
	call fdc_read_id
	ld a,1
	jr c,df_sides
	ld a,(res_buf)
	and &c0
	ld a,1
	jr nz,df_sides
	ld a,(res_buf+4)
	cp 1
	ld a,1
	jr nz,df_sides
	inc a
df_sides:
	ld (n_sides),a
	;; tracks
	ld a,(opt_tracks)
	ld hl,trk_opt_values
	ld e,a
	ld d,0
	add hl,de
	ld a,(hl)
	or a
	jr nz,df_tracks
	ld a,40				; auto
	ld hl,dstep
	bit 1,(hl)
	jr nz,df_tracks			; double stepping = 40 track disc
	ld a,(fmt_tracks)
	or a
	jr nz,df_tracks
	ld a,(n_sides)			; unknown: 80 if double sided
	cp 2
	ld a,40
	jr nz,df_tracks
	ld a,80
df_tracks:
	cp MAXTRACK+1
	jr c,df_tok
	ld a,MAXTRACK
df_tok:
	ld (n_tracks),a
	;; start with 10 rows per side, grow to 16 when a track needs it
	ld a,(t0_count)
	cp 11
	ld a,10
	jr c,df_slots
	ld a,MAXSLOT
df_slots:
	ld (disp_slots),a
	ret

trk_opt_values:	db 0,40,42,80

;; format table: lowest sector ID, sector count (0=any), CP/M system
;; tracks, tracks (0=probe), sides (0=probe), name (255 terminated)
FMT_SIZE	equ 17
fmt_table:
	db &c1,0,0,40,1,"DATA       ",255
	db &41,0,2,40,1,"SYSTEM     ",255
	db &01,8,0,40,1,"IBM        ",255
	db &01,9,0, 0,0,"D1 OR +3   ",255
	db &21,0,0,80,2,"ROMDOS D2  ",255
	db &11,0,0,80,2,"ROMDOS D10 ",255
	db &91,0,0,80,1,"PARADOS 80 ",255
	db &81,0,0,41,1,"PARADOS 41 ",255
	db &a1,0,0,40,2,"PARADOS 40D",255
	db &00,0,0, 0,0,"CUSTOM     ",255
fmt_blank:
	db &00,0,0,40,0,"NO FORMAT  ",255

;; ==========================================================================
;; Scan one track: (scan_t) = logical track, (scan_s) = side
;; ==========================================================================
scan_track:
	ld a,(scan_t)
	ld d,a
	ld a,(scan_s)
	ld e,a
	call entry_addr
	ld (cur_entry),hl
	;; clear the entry
	ld (hl),0
	ld d,h
	ld e,l
	inc de
	ld bc,ENTRY_SIZE-1
	ldir

	ld a,(scan_t)
	ld b,a
	ld a,(dstep)
	cp 2
	ld a,b
	jr nz,st_single
	add a,a
st_single:
	call seek_phys
	jr c,st_error

	call collect_ids
	cp TS_OK
	jr z,st_ids
	ld hl,(cur_entry)
	ld (hl),a
	cp TS_UNFORM
	ret nz
	ld hl,cnt_unf
	inc (hl)
	ret
st_error:
	ld hl,(cur_entry)
	ld (hl),TS_ERROR
	ret

st_ids:
	ld hl,(cur_entry)
	ld (hl),TS_OK
	inc hl
	ld a,(idcount)
	ld (hl),a
	call sort_ids
	;; copy up to MAXSLOT IDs into the slots
	ld a,(idcount)
	cp MAXSLOT+1
	jr c,st_n
	ld a,MAXSLOT
st_n:
	ld (st_nslots),a
	ld b,a
	ld hl,idlist
	ld de,(cur_entry)
	inc de
	inc de
st_copy:
	push bc
	ld bc,5				; C,H,R,N,ST1 (from READ ID)
	ldir
	xor a
	ld (de),a			; ST2
	inc de
	ld (de),a			; class
	inc de
	ld (de),a			; tries
	inc de
	pop bc
	djnz st_copy

	;; read every sector
	xor a
	ld (st_slot),a
st_read:
	ld a,(st_slot)
	call slot_addr			; HL -> slot
	ld a,(hl)
	ld de,SL_ST1
	add hl,de
	bit 5,(hl)			; ID field had a CRC error in READ ID
	jr z,st_do_read
	inc hl
	inc hl				; -> class
	ld (hl),CL_IDERR
	ld a,CL_IDERR
	jr st_count
st_do_read:
	ld a,(st_slot)
	call slot_addr
	call read_slot			; A = class
st_count:
	call count_class
	ld hl,st_slot
	inc (hl)
	ld a,(st_nslots)
	cp (hl)
	jr nz,st_read
	ret

;; HL = address of slot A of the current entry
slot_addr:
	ld hl,(cur_entry)
	inc hl
	inc hl
	add a,a
	add a,a
	add a,a				; *8
	ld e,a
	ld d,0
	add hl,de
	ret

;; update running totals for class A
count_class:
	ld hl,cnt_bad
	cp CL_CRC
	jr z,cc_inc
	cp CL_IDERR
	jr z,cc_inc
	cp CL_OTHER
	jr z,cc_inc
	ld hl,cnt_weak
	cp CL_SOFT
	jr z,cc_inc
	ld hl,cnt_ok
cc_inc:
	ld e,(hl)
	inc hl
	ld d,(hl)
	inc de
	ld (hl),d
	dec hl
	ld (hl),e
	ret

;; --------------------------------------------------------------------------
;; Read the sector described by the slot at HL, with retries.
;; Stores ST1/ST2 (of the first attempt), class and tries in the slot.
;; out: A = class
;; --------------------------------------------------------------------------
read_slot:
	ld (rs_slot),hl
	xor a
	ld (rs_tries),a
rsl_try:
	ld hl,(rs_slot)
	ld a,(scan_s)
	call fdc_read_sector
	call eval_result		; A = 0 ok, CL_DELETED, or error class
	ld (rs_class),a
	ld a,(rs_tries)
	or a
	jr nz,rsl_nostore		; keep the status of the first attempt
	ld hl,(rs_slot)
	ld de,SL_ST1
	add hl,de
	ld a,(res_buf+1)
	ld (hl),a
	inc hl
	ld a,(res_buf+2)
	ld (hl),a
rsl_nostore:
	ld a,(rs_class)
	or a
	jr z,rsl_good
	cp CL_DELETED
	jr z,rsl_good
	;; error - retry?
	ld a,(opt_retries)
	ld b,a
	ld a,(rs_tries)
	cp b
	jr nc,rsl_store			; out of retries, keep the error class
	inc a
	ld (rs_tries),a
	jr rsl_try
rsl_good:
	ld a,(rs_tries)
	or a
	ld a,CL_SOFT			; needed a retry: weak sector
	jr nz,rsl_setclass
	ld a,(rs_class)
	cp CL_DELETED
	jr z,rsl_setclass
	ld hl,(rs_slot)
	ld de,SL_N
	add hl,de
	ld a,(hl)
	call classify			; what kind of data is it?
rsl_setclass:
	ld (rs_class),a
rsl_store:
	ld hl,(rs_slot)
	ld de,SL_CLASS
	add hl,de
	ld a,(rs_class)
	ld (hl),a
	inc hl
	ld a,(rs_tries)
	ld (hl),a
	ld a,(rs_class)
	ret

;; --------------------------------------------------------------------------
;; Turn the READ DATA result in res_buf into a class
;; out: A = 0 (ok), CL_DELETED, CL_CRC, CL_IDERR or CL_OTHER
;; --------------------------------------------------------------------------
eval_result:
	ld a,(res_ok)
	or a
	ld a,CL_OTHER
	ret z				; timeout
	ld a,(res_buf)
	bit 3,a				; ST0 NR - not ready
	ld a,CL_OTHER
	ret nz
	ld a,(res_buf+1)
	and &35				; ST1: DE OR ND MA
	ld b,a
	ld a,(res_buf+2)
	and &33				; ST2: DD WC BC MD
	or b
	jr nz,er_error
	;; no error bits.  IC=01 with only EN set is the normal end of a
	;; single sector read (R = EOT); IC=10 / 11 is a failure.
	ld a,(res_buf)
	and &80
	ld a,CL_OTHER
	ret nz
	ld a,(res_buf+2)
	and &40				; ST2 CM - deleted data mark
	ret z				; A = 0 : ok
	ld a,CL_DELETED
	ret
er_error:
	ld a,(res_buf+1)
	bit 4,a				; OR - overrun
	ld a,CL_OTHER
	ret nz
	ld a,(res_buf+2)
	bit 5,a				; DD - CRC error in data field
	ld a,CL_CRC
	ret nz
	;; DE without DD.  If data bytes arrived the CRC error must be in the
	;; data field (an ID CRC error stops the FDC before any data moves);
	;; some emulators do not set DD.
	ld a,(res_buf+1)
	bit 5,a
	jr z,er_id
	ld hl,(rd_count)
	ld a,h
	or l
	ld a,CL_CRC
	ret nz
er_id:
	ld a,CL_IDERR			; DE in ID, ND, MA, MD, WC, BC
	ret

;; --------------------------------------------------------------------------
;; Collect the sector IDs of the current track with READ ID.
;; READ ID returns the next ID passing under the head, so reading until
;; the sequence repeats gives every ID in physical order.
;; out: A = TS_OK / TS_UNFORM / TS_ERROR, idcount, idlist
;; --------------------------------------------------------------------------
collect_ids:
	xor a
	ld (idcount),a
	ld (ci_fails),a
	ld (ci_nr),a
ci_loop:
	ld a,(scan_s)
	call fdc_read_id
	jr c,ci_notready
	ld a,(res_buf)
	bit 3,a
	jr nz,ci_notready
	and &c0
	jr z,ci_good
	ld a,(res_buf+1)
	bit 5,a				; DE: ID found but its CRC is bad
	jr nz,ci_crc
	;; no ID found at all within two index pulses
	ld a,(idcount)
	or a
	ld a,TS_UNFORM
	ret z
	ld hl,ci_fails
	inc (hl)
	ld a,(hl)
	cp 3
	jr c,ci_loop
	ld a,TS_OK
	ret
ci_notready:
	;; the motor may have been switched off (e.g. by the AMSDOS timeout);
	;; spin it up again and try once more
	ld a,(ci_nr)
	or a
	ld a,TS_ERROR
	ret nz
	ld a,1
	ld (ci_nr),a
	xor a
	ld (motor_state),a
	call motor_on
	jr ci_loop
ci_crc:
	ld a,&20
	jr ci_add
ci_good:
	xor a
ci_add:
	push af
	ld a,(idcount)
	call id_addr
	ex de,hl
	ld hl,res_buf+3			; C,H,R,N
	ld bc,4
	ldir
	pop af
	ld (de),a			; ST1 flag (&20 = ID CRC error)
	ld hl,idcount
	inc (hl)
	ld a,(hl)
	cp 3
	jr c,ci_loop
	;; n >= 3 : does id[n-2],id[n-1] repeat id[0],id[1] ?
	sub 2
	ld (ci_period),a
	call id_addr
	ld de,idlist
	call cmp_id
	jr nz,ci_more
	ld a,(ci_period)
	inc a
	call id_addr
	ld de,idlist+5
	call cmp_id
	jr nz,ci_more
	ld a,(ci_period)
	ld (idcount),a
	ld a,TS_OK
	ret
ci_more:
	ld a,(idcount)
	cp MAXIDS
	jp c,ci_loop
	ld a,TS_OK
	ret

;; HL = idlist + A*5
id_addr:
	ld l,a
	ld h,0
	ld e,l
	ld d,h
	add hl,hl
	add hl,hl
	add hl,de
	ld de,idlist
	add hl,de
	ret

;; compare the 4 byte CHRN at HL and DE, Z if equal
cmp_id:
	ld b,4
cid_loop:
	ld a,(de)
	cp (hl)
	ret nz
	inc hl
	inc de
	djnz cid_loop
	ret

;; bubble sort idlist (5 byte entries) by sector ID R (stable)
sort_ids:
	ld a,(idcount)
	cp 2
	ret c
so_pass:
	xor a
	ld (so_swapped),a
	ld a,(idcount)
	dec a
	ld b,a
	ld hl,idlist
so_cmp:
	push bc
	ld d,h
	ld e,l
	inc de
	inc de
	inc de
	inc de
	inc de				; DE -> next entry
	inc hl
	inc hl
	ld a,(hl)			; R of this entry
	dec hl
	dec hl
	inc de
	inc de
	ex de,hl
	cp (hl)				; compare with R of next entry
	ex de,hl
	dec de
	dec de
	jr c,so_noswap
	jr z,so_noswap
	push hl
	ld b,5
so_swap:
	ld a,(de)
	ld c,(hl)
	ld (hl),a
	ld a,c
	ld (de),a
	inc hl
	inc de
	djnz so_swap
	pop hl
	ld a,1
	ld (so_swapped),a
so_noswap:
	ld de,5
	add hl,de
	pop bc
	djnz so_cmp
	ld a,(so_swapped)
	or a
	jr nz,so_pass
	ret

;; ==========================================================================
;; Data classification.  in: A = N (sector size code), data in BUFFER
;; out: A = class
;; ==========================================================================
classify:
	;; length = 128 << N, at most 8192 (the size of the buffer)
	ld hl,128
	cp 6
	jr c,cl_shift
	ld a,6
cl_shift:
	or a
	jr z,cl_len
	add hl,hl
	dec a
	jr cl_shift
cl_len:
	ld (cl_length),hl

	;; every byte the same?
	ld hl,BUFFER
	ld e,(hl)
	ld bc,(cl_length)
cl_uni:
	ld a,(hl)
	cp e
	jr nz,cl_notuni
	inc hl
	dec bc
	ld a,b
	or c
	jr nz,cl_uni
	ld a,e
	cp &e5
	ld a,CL_EMPTY
	ret z
	ld a,CL_FILL
	ret
cl_notuni:
	;; CP/M system tracks of a SYSTEM format disc
	ld a,(fmt_sys)
	ld b,a
	ld a,(scan_t)
	cp b
	ld a,CL_SYSTEM
	ret c
	call is_header
	ld a,CL_HEADER
	ret z
	call is_dir
	ld a,CL_DIR
	ret z
	call is_text
	ld a,CL_TEXT
	ret z
	ld a,CL_BINARY
	ret

;; AMSDOS header: 16 bit sum of bytes 0..66 stored at 67/68.  Z if valid.
is_header:
	ld hl,BUFFER
	ld de,0
	ld b,67
ih_sum:
	ld a,(hl)
	add a,e
	ld e,a
	ld a,d
	adc a,0
	ld d,a
	inc hl
	djnz ih_sum
	ld a,d
	or e
	jr z,ih_no			; all zero - not a header
	ld a,(hl)
	cp e
	ret nz
	inc hl
	ld a,(hl)
	cp d
	ret
ih_no:
	inc a				; A was 0 -> NZ
	ret

;; CP/M directory: 32 byte entries, each unused (&E5) or user 0-15 / &20 /
;; &21 followed by 11 printable name characters.  Z if directory.
is_dir:
	ld hl,(cl_length)
	ld a,h
	cp 8+1				; more than 2K: not a directory sector
	jr nc,id_no
	;; entries = length / 32
	ld b,5
id_div:
	srl h
	rr l
	djnz id_div
	ld b,l
	ld c,0				; entries in use
	ld hl,BUFFER
id_ent:
	ld a,(hl)
	cp &e5
	jr z,id_next
	cp &22
	jr nc,id_no
	cp &20
	jr nc,id_used			; &20 label / &21 date stamps
	cp 16
	jr nc,id_no
	push hl
	inc hl
	ld d,11
id_chr:
	ld a,(hl)
	and &7f				; attribute bits live in bit 7
	cp &20
	jr c,id_nopop
	cp &7f
	jr nc,id_nopop
	inc hl
	dec d
	jr nz,id_chr
	pop hl
id_used:
	inc c
id_next:
	ld de,32
	add hl,de
	djnz id_ent
	ld a,c
	or a
	jr z,id_no
	xor a
	ret
id_nopop:
	pop hl
id_no:
	ld a,1
	or a
	ret

;; text: at most 1/16 of the bytes outside printable ASCII + TAB LF CR ^Z
is_text:
	ld hl,(cl_length)
	ld b,4
it_div:
	srl h
	rr l
	djnz it_div
	ld (cl_limit),hl
	ld hl,BUFFER
	ld bc,(cl_length)
	ld de,0
it_loop:
	ld a,(hl)
	cp &7f
	jr nc,it_bad
	cp &20
	jr nc,it_ok
	cp 9
	jr z,it_ok
	cp 10
	jr z,it_ok
	cp 13
	jr z,it_ok
	cp 26
	jr z,it_ok
it_bad:
	inc de
it_ok:
	inc hl
	dec bc
	ld a,b
	or c
	jr nz,it_loop
	ld hl,(cl_limit)
	and a
	sbc hl,de
	jr c,it_no
	xor a
	ret
it_no:
	ld a,1
	or a
	ret

;; ==========================================================================
;; uPD765 low level
;; ==========================================================================

;; motor on; waits ~1 second for spin up if it was off
motor_on:
	ld bc,MOTOR_PORT
	ld a,1
	out (c),a
	ld a,(motor_state)
	or a
	ret nz
	ld a,1
	ld (motor_state),a
	ld b,4
mo_wait:
	ld a,250
	call delay_ms
	djnz mo_wait
	ret

motor_off:
	ld bc,MOTOR_PORT
	xor a
	out (c),a
	ld (motor_state),a
	ret

;; delay A milliseconds (A=0 : 256ms), preserves BC DE HL
delay_ms:
	push bc
dm_ms:
	ld b,250
dm_in:
	djnz dm_in			; 250 * 4us = 1ms
	dec a
	jr nz,dm_ms
	pop bc
	ret

;; send byte A to the FDC.  BC is set to FDC_MSR.  Preserves DE HL.
fdc_out:
	ld bc,FDC_MSR
	push de
	push af
	ld d,32				; stale bytes we are prepared to drain
fo_wait:
	in a,(c)
	add a,a				; RQM -> carry
	jr nc,fo_wait
	add a,a				; DIO -> carry
	jr nc,fo_ready
	inc c				; FDC still has a result byte for us:
	in a,(c)			; throw it away and carry on
	dec c
	ld a,10
fo_dly:	dec a
	jr nz,fo_dly
	dec d				; no FDC at all (464 without DDI-1)
	jr nz,fo_wait			; reads &FF forever: give up
	pop af
	pop de
	ret
fo_ready:
	pop af
	pop de
	inc c
	out (c),a
	dec c
	ex (sp),hl			; give the FDC time to update its status
	ex (sp),hl
	ret

;; read the result phase into res_buf.
;; out: carry set (and res_ok = 0) on timeout, res_count = bytes read
fdc_result:
	ld hl,res_buf
	ld bc,FDC_MSR
fr_next:
	ld de,0
fr_wait:
	in a,(c)
	add a,a				; RQM
	jr nc,fr_busy
	add a,a				; DIO
	jr nc,fr_done			; FDC wants a command again: finished
	inc c
	in a,(c)
	dec c
	ld (hl),a
	ld de,res_buf+15		; more than 15 bytes: no working FDC
	ld a,l
	cp e
	jr nz,fr_inc
	ld a,h
	cp d
	jr z,fr_fail
fr_inc:
	inc hl
	ex (sp),hl
	ex (sp),hl
	jr fr_next
fr_busy:
	dec de
	ld a,d
	or e
	jr nz,fr_wait
fr_fail:
	xor a
	ld (res_ok),a
	scf
	ret
fr_done:
	ld de,res_buf
	and a
	sbc hl,de
	ld a,l
	ld (res_count),a
	ld a,1
	ld (res_ok),a
	and a
	ret

;; flush pending interrupts (drive status changes)
fdc_flush:
	ld e,8
ff_loop:
	ld a,&08			; SENSE INTERRUPT STATUS
	call fdc_out
	push de
	call fdc_result
	pop de
	ld a,(res_buf)
	cp &80				; invalid command = nothing pending
	ret z
	dec e
	jr nz,ff_loop
	ret

;; motor on, SPECIFY, RECALIBRATE, SENSE DRIVE STATUS
;; out: carry set if the drive is not ready
fdc_start:
	call motor_on
	call fdc_flush
	ld a,&03			; SPECIFY
	call fdc_out
	ld a,&a1			; step rate 12ms, head unload 16ms (4MHz clock)
	call fdc_out
	ld a,&03			; head load 4ms, non-DMA mode
	call fdc_out
	ld a,&ff
	ld (cur_phys),a
	call fdc_recal
	call fdc_recal			; again: 80 track drives need > 77 steps
	jr c,fs_fail
	;; SENSE DRIVE STATUS -> ST3
	ld a,&04
	call fdc_out
	call drive_head0
	call fdc_out
	call fdc_result
	jr c,fs_fail
	ld a,(res_buf)
	ld (st3),a
	and &20				; RY - ready
	jr z,fs_fail
	and a
	ret
fs_fail:
	scf
	ret

;; A = drive number for command byte 2 (head 0)
drive_head0:
	ld a,(opt_drive)
	ret

;; RECALIBRATE; carry set on failure
fdc_recal:
	ld a,&07
	call fdc_out
	call drive_head0
	call fdc_out
	call fdc_wait_seek
	ld a,&ff
	jr c,frc_set
	xor a
frc_set:
	ld (cur_phys),a
	ret

;; seek to physical track A (if not already there); carry set on failure
seek_phys:
	ld hl,cur_phys
	cp (hl)
	ret z
	ld (sp_target),a
	ld a,&0f			; SEEK
	call fdc_out
	call drive_head0
	call fdc_out
	ld a,(sp_target)
	call fdc_out
	call fdc_wait_seek
	jr c,sp_fail
	ld a,(sp_target)
	ld (cur_phys),a
	ld a,15				; head settle time
	call delay_ms
	and a
	ret
sp_fail:
	ld a,&ff
	ld (cur_phys),a
	scf
	ret

;; poll SENSE INTERRUPT STATUS until the seek / recalibrate ends
;; carry set if it failed or took too long (~3s)
fdc_wait_seek:
	ld hl,3000
fws_loop:
	push hl
	ld a,1
	call delay_ms
	ld a,&08
	call fdc_out
	call fdc_result
	pop hl
	jr c,fws_again
	ld a,(res_buf)
	cp &80
	jr z,fws_again			; nothing yet
	bit 5,a				; SE - seek end
	jr z,fws_again
	and &c0				; IC = 00 : ok
	ret z
	scf
	ret
fws_again:
	dec hl
	ld a,h
	or l
	jr nz,fws_loop
	scf
	ret

;; READ ID on head A of the selected drive; result in res_buf
;; carry set on timeout
fdc_read_id:
	add a,a
	add a,a
	ld e,a
	ld a,(opt_drive)
	or e
	ld e,a
	ld a,&4a			; READ ID, MFM
	call fdc_out
	ld a,e
	call fdc_out
	jp fdc_result

;; --------------------------------------------------------------------------
;; READ DATA of one sector.  in: HL -> C,H,R,N   A = head
;; The data goes into the 8K ring buffer at BUFFER; the result into res_buf.
;; carry set on timeout
;; --------------------------------------------------------------------------
fdc_read_sector:
	add a,a
	add a,a
	ld e,a
	ld a,(opt_drive)
	or e
	ld de,cmd_buf+1
	ld (de),a			; head / unit
	inc de
	ld bc,4
	ldir				; C H R N
	dec hl
	dec hl
	ld a,(hl)			; EOT = R (read just this sector)
	ld (de),a
	inc de
	ld a,&2a			; GPL
	ld (de),a
	inc de
	inc hl
	ld a,(hl)			; N
	or a
	ld a,&ff			; DTL (only used when N = 0)
	jr nz,frs_dtl
	ld a,&80
frs_dtl:
	ld (de),a
	ld a,&46			; READ DATA, MFM, no multi-track, no skip
	ld (cmd_buf),a

	di				; no interrupts while bytes are moving
	ld hl,cmd_buf
	ld e,9
frs_send:
	ld a,(hl)
	call fdc_out
	inc hl
	dec e
	jr nz,frs_send
	;; execution phase: a byte must be taken every 32us.
	;; The ring buffer wraps from &A000 back to &8000 (res 5,h) so a
	;; huge sector (N>=6) can never overwrite anything else.
	;; DE counts the bytes received.
	ld hl,BUFFER
	ld de,0
	ld bc,FDC_MSR
frs_wait:
	in a,(c)
	jp p,frs_wait			; wait for RQM
	and &20				; still in execution phase?
	jr z,frs_end
	inc c
	ini				; (HL) <- data, HL+1, B-1
	inc b
	dec c
	res 5,h
	inc de
	jp frs_wait
frs_end:
	ld (rd_count),de
	call fdc_result
	ei
	ret

;; ==========================================================================
;; Results table
;; ==========================================================================

;; HL = table entry for track D, side E
entry_addr:
	ld a,d
	add a,a
	add a,e				; index = track*2 + side
	ld l,a
	ld h,0
	add hl,hl			; *2
	ld b,h
	ld c,l
	add hl,hl
	add hl,hl
	add hl,hl
	add hl,hl
	add hl,hl
	add hl,hl			; *128
	add hl,bc			; *130
	ld bc,TABLE
	add hl,bc
	ret

clear_table:
	ld hl,TABLE
	ld de,TABLE+1
	ld bc,MAXTRACK*2*ENTRY_SIZE-1
	ld (hl),0
	ldir
	ret

;; ink for track D, side E, slot C -> A
cell_ink:
	push bc
	call entry_addr
	pop bc
	ld a,(hl)
	cp TS_UNFORM
	ld a,CL_UNFORM
	ret z
	ld a,(hl)
	cp TS_ERROR
	ld a,CL_OTHER
	ret z
	ld a,(hl)
	cp TS_OK
	ld a,CL_NONE
	ret nz
	inc hl
	ld a,c
	cp (hl)				; slot >= sector count?
	ld a,CL_NONE
	ret nc
	ld a,c
	cp MAXSLOT
	ld a,CL_NONE
	ret nc
	inc hl
	ld a,c
	add a,a
	add a,a
	add a,a
	add a,SL_CLASS
	ld c,a
	ld b,0
	add hl,bc
	ld a,(hl)
	ret

;; ==========================================================================
;; Screen layout and drawing (mode 0, 160x200, 16 inks)
;; ==========================================================================

;; work out cell sizes from n_tracks, n_sides, disp_slots
setup_layout:
	ld a,(n_tracks)
	cp 41
	ld a,2
	jr c,sl_w
	ld a,1
sl_w:
	ld (cell_w),a
	ld b,a
	ld a,(n_tracks)
	ld c,a
	xor a
sl_mul:
	add a,c
	djnz sl_mul
	ld b,a				; grid width in bytes
	ld a,80
	sub b
	srl a
	ld (grid_x0),a
	;; row height: [sides][slots]
	ld a,(n_sides)
	cp 2
	ld hl,layout_1side
	jr nz,sl_s
	ld hl,layout_2side
sl_s:
	ld a,(disp_slots)
	cp MAXSLOT
	jr nz,sl_10
	inc hl
	inc hl
sl_10:
	ld a,(hl)
	ld (slot_h),a
	inc hl
	ld a,(hl)
	ld (cell_h),a
	ret

;; slot height, coloured height  for 10 slots, then for 16 slots
layout_1side:	db 14,12, 9,8
layout_2side:	db 6,5, 4,3

GRID_Y0		equ 24		; side 0 grid starts on line 24
GRID_Y1		equ 96		; side 1 grid starts on line 96

;; grow to 16 rows if the track just scanned has more than 10 sectors
check_layout:
	ld a,(disp_slots)
	cp MAXSLOT
	ret z
	ld hl,(cur_entry)
	ld a,(hl)
	cp TS_OK
	ret nz
	inc hl
	ld a,(disp_slots)
	cp (hl)
	ret nc
	ld a,MAXSLOT
	ld (disp_slots),a
	call setup_layout
	call clear_grid
	call draw_ticks
	jp draw_all_columns

;; full redraw of the map screen
draw_screen:
	xor a
	call SCR_SET_MODE
	ld hl,0
	call SCR_SET_OFFSET
	ld a,INK_TEXT
	call TXT_SET_PEN
	;; line 1: "DISC TEST DRIVE A WP"
	ld hl,msg_title
	call print_str
	ld a,(opt_drive)
	add a,"A"
	call TXT_OUTPUT
	ld a,(st3)
	and &40
	jr z,ds_nowp
	ld hl,msg_wp
	call print_str
ds_nowp:
	;; line 2: format name, tracks, sides
	ld hl,&0102
	call TXT_SET_CURSOR
	ld hl,(fmt_name)
	call print_str
	ld a," "
	call TXT_OUTPUT
	ld a,(n_tracks)
	call print_dec2
	ld a,"T"
	call TXT_OUTPUT
	ld a," "
	call TXT_OUTPUT
	ld a,(n_sides)
	add a,"0"
	call TXT_OUTPUT
	ld a,"S"
	call TXT_OUTPUT
	call draw_ticks
	jp draw_all_columns

msg_title:	db 31,1,1,"DISC TEST DRIVE ",255
msg_wp:		db " WP",255

;; clear the map area (lines 16..167)
clear_grid:
	ld b,16
	ld c,0
	call scr_addr
	ld b,152
	ld c,80
	ld de,0
	jp fill_cell

;; track markers above each side: tall every 10 tracks, short every 5
draw_ticks:
	ld a,GRID_Y0-8
	call draw_tick_row
	ld a,(n_sides)
	cp 2
	ret nz
	ld a,GRID_Y1-8
draw_tick_row:
	ld (dt_y),a
	ld a,(enc_tab+INK_TEXT)
	and &aa				; left pixel only
	ld (dt_pat),a
	xor a
	ld (dt_t),a
dt_loop:
	ld a,(dt_t)
	ld c,5
	call div_a_c			; A = remainder
	or a
	jr nz,dt_next
	ld a,(dt_t)
	ld c,10
	call div_a_c
	or a
	ld a,2
	jr nz,dt_h
	ld a,5
dt_h:
	ld (dt_hgt),a
	ld a,(dt_t)
	call track_x			; (uses B)
	ld c,a
	ld a,(dt_hgt)
	ld b,a
	ld a,(dt_y)
	add a,7
	sub b				; bottom aligned on line y+6
	ld b,a
	call scr_addr
	ld a,(dt_hgt)
	ld b,a
	ld c,1
	ld a,(dt_pat)
	ld d,a
	ld e,a
	call fill_cell
dt_next:
	ld hl,dt_t
	inc (hl)
	ld a,(n_tracks)
	cp (hl)
	jr nz,dt_loop
	ret

;; A mod C -> A (A,C < 256)
div_a_c:
	sub c
	jr nc,div_a_c
	add a,c
	ret

;; A = screen byte x of track A
track_x:
	ld b,a
	ld a,(cell_w)
	cp 2
	ld a,b
	jr nz,tx_1
	add a,a
tx_1:
	ld b,a
	ld a,(grid_x0)
	add a,b
	ret

draw_all_columns:
	ld a,(n_sides)
	ld e,0
dac_side:
	ld d,0
dac_track:
	push de
	call draw_column
	pop de
	inc d
	ld a,(n_tracks)
	cp d
	jr nz,dac_track
	inc e
	ld a,(n_sides)
	cp e
	jr nz,dac_side
	ret

;; draw all cells of track D side E in their own colours
draw_column:
	ld a,&ff
;; draw all cells of track D side E in ink A (&FF = own colours)
draw_column_ink:
	ld (dcol_ink),a
	ld c,0
dcol_loop:
	push bc
	push de
	ld a,(dcol_ink)
	cp &ff
	jr nz,dcol_draw
	call cell_ink
dcol_draw:
	pop de
	pop bc
	push bc
	push de
	call draw_cell
	pop de
	pop bc
	inc c
	ld a,(disp_slots)
	cp c
	jr nz,dcol_loop
	ret


;; draw cell for track D, side E, slot C in ink A
draw_cell:
	ld (dc_ink),a
	ld a,d
	call track_x			; (uses B)
	ld (dc_x),a
	;; y = side start + slot * slot_h
	ld a,e
	or a
	ld a,GRID_Y0
	jr z,dc_y0
	ld a,GRID_Y1
dc_y0:
	ld b,c
	inc b
	ld hl,slot_h
	jr dc_ydo
dc_ymul:
	add a,(hl)
dc_ydo:
	djnz dc_ymul
	ld b,a
	ld a,(dc_x)
	ld c,a
	call scr_addr
	;; screen bytes for the ink
	push hl
	ld a,(dc_ink)
	ld e,a
	ld d,0
	ld hl,enc_tab
	add hl,de
	ld a,(hl)
	pop hl
	ld e,a				; both pixels
	and &aa
	ld d,a				; last byte: left pixel only (gap)
	ld a,(cell_h)
	ld b,a
	ld a,(cell_w)
	ld c,a
	jp fill_cell

;; HL = screen address of byte column C on pixel line B (screen at &C000,
;; offset 0).  Preserves BC DE.
scr_addr:
	push bc
	push de
	ld a,b
	rrca
	rrca
	rrca
	and &1f				; character row
	ld l,a
	ld h,0
	add hl,hl
	add hl,hl
	add hl,hl
	add hl,hl			; *16
	ld d,h
	ld e,l
	add hl,hl
	add hl,hl			; *64
	add hl,de			; *80
	ld e,c
	ld d,0
	add hl,de
	ld a,b
	and 7
	add a,a
	add a,a
	add a,a				; (line and 7) * &800
	add a,&c0
	add a,h
	ld h,a
	pop de
	pop bc
	ret

;; fill B lines of C bytes from HL.  Every byte = E except the last byte of
;; each line = D.
fill_cell:
	push hl
	push bc
	ld b,c
	dec b
	jr z,fc_last
fc_byte:
	ld (hl),e
	inc hl
	djnz fc_byte
fc_last:
	ld (hl),d
	pop bc
	pop hl
	call next_line
	djnz fill_cell
	ret

;; HL = same byte one pixel line lower
next_line:
	ld a,h
	add a,8
	ld h,a
	ret nc
	push de
	ld de,&c050
	add hl,de
	pop de
	ret

;; ==========================================================================
;; Map viewer - move a cursor over the map and inspect sectors
;; ==========================================================================
viewer:
	xor a
	ld (cur_t),a
	ld (cur_s),a
	ld (cur_slot),a
vw_loop:
	call cursor_on
	call KM_READ_CHAR		; more keys queued (auto repeat)?  then
	jr c,vw_key			; skip the slow text update
	call show_info
	call KM_WAIT_CHAR
vw_key:
	push af
	call cursor_off
	pop af
	cp K_UP
	jr z,vw_up
	cp K_DOWN
	jr z,vw_down
	cp K_LEFT
	jr z,vw_left
	cp K_RIGHT
	jr z,vw_right
	cp K_SLEFT
	jp z,vw_left10
	cp K_SRIGHT
	jp z,vw_right10
	cp K_ENTER
	jp z,vw_dump
	cp K_COPY
	jp z,vw_dump
	cp K_ESC
	ret z
	and &df				; upper case
	cp "D"
	jp z,vw_dump
	cp "L"
	jp z,vw_legend
	cp "M"
	ret z
	jr vw_loop

vw_up:
	ld a,(cur_slot)
	or a
	jr z,vw_up_side
	dec a
	ld (cur_slot),a
	jr vw_loop
vw_up_side:
	ld a,(cur_s)
	or a
	jr z,vw_loop
	xor a
	ld (cur_s),a
	ld a,(disp_slots)
	dec a
	ld (cur_slot),a
	jr vw_loop
vw_down:
	ld a,(disp_slots)
	ld b,a
	ld a,(cur_slot)
	inc a
	cp b
	jr nc,vw_down_side
	ld (cur_slot),a
	jr vw_loop
vw_down_side:
	ld a,(n_sides)
	cp 2
	jp nz,vw_loop
	ld a,(cur_s)
	or a
	jp nz,vw_loop
	inc a
	ld (cur_s),a
	xor a
	ld (cur_slot),a
	jp vw_loop
vw_left:
	ld a,(cur_t)
	or a
	jp z,vw_loop
	dec a
	ld (cur_t),a
	jp vw_loop
vw_right:
	ld a,(n_tracks)
	ld b,a
	ld a,(cur_t)
	inc a
	cp b
	jp nc,vw_loop
	ld (cur_t),a
	jp vw_loop
vw_left10:
	ld a,(cur_t)
	sub 10
	jr nc,vw_l10
	xor a
vw_l10:
	ld (cur_t),a
	jp vw_loop
vw_right10:
	ld a,(n_tracks)
	dec a
	ld b,a
	ld a,(cur_t)
	add a,10
	cp b
	jr c,vw_r10
	ld a,b
vw_r10:
	ld (cur_t),a
	jp vw_loop
vw_dump:
	call dump_view
	call draw_screen
	jp vw_loop
vw_legend:
	call legend_view
	call draw_screen
	jp vw_loop

cursor_on:
	call cursor_pos
	ld a,INK_CURSOR
	jp draw_cell
cursor_off:
	call cursor_pos
	push bc
	push de
	call cell_ink
	pop de
	pop bc
	jp draw_cell
;; D = cursor track, E = side, C = slot
cursor_pos:
	ld a,(cur_t)
	ld d,a
	ld a,(cur_s)
	ld e,a
	ld a,(cur_slot)
	ld c,a
	ret

;; clear the 4 info lines at the bottom
clear_info:
	ld hl,msg_clear
	jp print_str
msg_clear:
	db 31,1,22,"                    "
	db 31,1,23,"                    "
	db 31,1,24,"                    "
	db 31,1,25,"                   ",255

;; --------------------------------------------------------------------------
;; Show the details of the sector under the cursor on lines 22-25
;; --------------------------------------------------------------------------
show_info:
	ld hl,msg_inf_t
	call print_str
	ld a,(cur_t)
	call print_dec2
	ld hl,msg_inf_s
	call print_str
	ld a,(cur_s)
	add a,"0"
	call TXT_OUTPUT
	ld hl,msg_inf_n
	call print_str
	ld a,(cur_slot)
	inc a
	call print_dec2
	call cursor_pos
	call entry_addr
	ld a,(hl)
	cp TS_OK
	jr z,si_ok
	ld hl,msg_notscanned
	cp TS_NONE
	jr z,si_last
	ld hl,msg_unform
	cp TS_UNFORM
	jr z,si_last
	ld hl,msg_trkerr
si_last:
	;; track / slot without a sector: blank lines 22-24 after the header
	push hl
	call pad_line
	ld hl,msg_blank23
	call print_str
	ld hl,&0119
	call TXT_SET_CURSOR
	pop hl
	call print_str
	jp pad_line

si_ok:
	inc hl
	ld a,"/"
	call TXT_OUTPUT
	ld a,(hl)			; sectors on this track
	call print_dec2
	ld b,(hl)
	inc hl
	ld a,(cur_slot)
	cp MAXSLOT
	jr nc,si_nosec
	cp b
	jr c,si_sector
si_nosec:
	ld hl,msg_nosector
	jr si_last
si_sector:
	add a,a
	add a,a
	add a,a
	ld e,a
	ld d,0
	add hl,de
	ld (inf_slot),hl
	call pad_line
	;; line 23: CHRN
	ld hl,msg_inf_chrn
	call print_str
	ld hl,(inf_slot)
	ld b,4
si_chrn:
	ld a,(hl)
	call print_hex8
	ld a," "
	call TXT_OUTPUT
	inc hl
	djnz si_chrn
	call pad_line
	;; line 24: size, ST1, ST2, retries
	ld hl,msg_inf_size
	call print_str
	ld hl,(inf_slot)
	ld de,SL_N
	add hl,de
	ld a,(hl)
	call print_size
	ld hl,msg_inf_st
	call print_str
	ld hl,(inf_slot)
	ld de,SL_ST1
	add hl,de
	ld a,(hl)
	call print_hex8
	ld a," "
	call TXT_OUTPUT
	inc hl
	ld a,(hl)
	call print_hex8
	ld hl,(inf_slot)
	ld de,SL_TRIES
	add hl,de
	ld a,(hl)
	or a
	jr z,si_class
	push af
	ld hl,msg_inf_r
	call print_str
	pop af
	add a,"0"
	call TXT_OUTPUT
si_class:
	call pad_line
	;; line 25: what is it
	ld hl,&0119
	call TXT_SET_CURSOR
	ld hl,(inf_slot)
	call print_class
	jp pad_line

;; print spaces up to the end of the current line (column 20; column 19
;; on line 25 so the screen never scrolls)
pad_line:
	call TXT_GET_CURSOR
	ld a,l
	cp 25
	ld a,20
	jr nz,pl_limit
	dec a
pl_limit:
	ld b,a
pl_loop:
	ld a,b
	cp h				; carry once past the limit
	ret c
	ld a," "
	call TXT_OUTPUT
	inc h
	jr pl_loop

msg_inf_t:	db 31,1,22,"T",255
msg_inf_s:	db " S",255
msg_inf_n:	db " SEC ",255
msg_inf_chrn:	db 31,1,23,"CHRN ",255
msg_inf_size:	db 31,1,24,"SZ ",255
msg_inf_st:	db " ST ",255
msg_inf_r:	db " R",255
msg_notscanned:	db "NOT SCANNED",255
msg_unform:	db "UNFORMATTED TRACK",255
msg_trkerr:	db "NOT READY/NO SEEK",255
msg_nosector:	db "NO SECTOR",255
msg_blank23:	db 31,1,23,"                    "
		db 31,1,24,"                    ",255

;; print the size of a sector with size code A (128 << N)
print_size:
	cp 8
	jr c,ps_ok
	ld a,"?"
	jp TXT_OUTPUT
ps_ok:
	ld hl,128
	or a
ps_shift:
	jr z,ps_print
	add hl,hl
	dec a
	jr ps_shift
ps_print:
	jp print_dec

;; print the description of the slot at HL (19 chars max)
print_class:
	push hl
	ld de,SL_CLASS
	add hl,de
	ld a,(hl)
	pop hl
	cp CL_IDERR
	jr z,pc_iderr
	cp CL_OTHER
	jr z,pc_other
pc_table:
	ld hl,class_long
	jp print_nth
pc_iderr:
	ld de,SL_ST1
	add hl,de
	ld b,(hl)			; ST1
	inc hl
	ld c,(hl)			; ST2
	ld hl,msg_e_idcrc
	bit 5,b				; DE without DD: CRC error in the ID
	jr nz,pc_print
	ld hl,msg_e_nodam
	bit 0,c				; MD: no data address mark
	jr nz,pc_print
	ld hl,msg_e_notfound
	bit 2,b				; ND: sector not found
	jr nz,pc_print
	ld hl,msg_e_noam
	bit 0,b				; MA
	jr nz,pc_print
	ld a,CL_IDERR
	jr pc_table
pc_other:
	ld de,SL_ST1
	add hl,de
	ld a,(hl)
	ld hl,msg_e_overrun
	cp &ff
	jr z,pc_timeout
	bit 4,a
	jr nz,pc_print
pc_timeout:
	ld a,CL_OTHER
	jr pc_table
pc_print:
	jp print_str

msg_e_idcrc:	db "CRC ERROR IN ID",255
msg_e_nodam:	db "NO DATA ADDR MARK",255
msg_e_notfound:	db "SECTOR NOT FOUND",255
msg_e_noam:	db "NO ADDRESS MARK",255
msg_e_overrun:	db "OVERRUN (TIMING)",255

;; long class names, indexed by class (19 chars max)
class_long:
	db "NO SECTOR",255		; 0
	db "",255			; 1
	db "NOT READY/TIMEOUT",255	; 2
	db "EMPTY (&E5 FILL)",255	; 3
	db "UNIFORM FILLER",255		; 4
	db "DIRECTORY",255		; 5
	db "AMSDOS FILE HEADER",255	; 6
	db "TEXT / ASCII",255		; 7
	db "BINARY DATA",255		; 8
	db "CP/M SYSTEM TRACK",255	; 9
	db "DELETED DATA MARK",255	; 10
	db "WEAK: OK ON RETRY",255	; 11
	db "CRC ERROR IN DATA",255	; 12
	db "ID ERROR",255		; 13
	db "UNFORMATTED TRACK",255	; 14

;; short class names for the legend (10 chars max)
class_short:
	db "",255			; 0
	db "",255			; 1
	db "READ FAIL",255		; 2
	db "EMPTY (E5)",255		; 3
	db "FILLER",255			; 4
	db "DIRECTORY",255		; 5
	db "FILE HEADR",255		; 6
	db "TEXT",255			; 7
	db "BINARY",255			; 8
	db "SYSTEM TRK",255		; 9
	db "DELETED",255		; 10
	db "WEAK/RETRY",255		; 11
	db "DATA CRC",255		; 12
	db "ID/NOT FND",255		; 13
	db "UNFMT TRKS",255		; 14

;; ==========================================================================
;; Legend, statistics and key help
;; ==========================================================================
legend_view:
	;; count every class over the whole disc
	ld hl,cnt_class
	ld b,32
lv_zero:
	ld (hl),0
	inc hl
	djnz lv_zero
	ld e,0
lv_side:
	ld d,0
lv_track:
	push de
	call entry_addr
	ld a,(hl)
	cp TS_UNFORM
	ld c,CL_UNFORM
	jr z,lv_one
	cp TS_ERROR
	ld c,CL_OTHER
	jr z,lv_one
	cp TS_OK
	jr nz,lv_nexttrk
	inc hl
	ld a,(hl)			; sectors
	cp MAXSLOT+1
	jr c,lv_n
	ld a,MAXSLOT
lv_n:
	or a
	jr z,lv_nexttrk
	ld b,a
	inc hl
	ld de,SL_CLASS
	add hl,de
lv_slot:
	ld c,(hl)
	push hl
	call lv_inc
	pop hl
	ld de,SLOT_SIZE
	add hl,de
	djnz lv_slot
	jr lv_nexttrk
lv_one:
	call lv_inc
lv_nexttrk:
	pop de
	inc d
	ld a,(n_tracks)
	cp d
	jr nz,lv_track
	inc e
	ld a,(n_sides)
	cp e
	jr nz,lv_side

	;; draw the page
	xor a
	call SCR_SET_MODE
	ld hl,0
	call SCR_SET_OFFSET
	ld a,INK_TEXT
	call TXT_SET_PEN
	ld hl,msg_legend
	call print_str
	ld hl,legend_order
	ld a,3
	ld (lv_row),a
lv_entry:
	ld a,(hl)
	or a
	jr z,lv_text
	inc hl
	push hl
	ld (lv_class),a
	;; colour box: bytes 0-2, lines (row-1)*8+1 .. +6
	ld a,(lv_row)
	dec a
	add a,a
	add a,a
	add a,a
	inc a
	ld b,a
	ld c,0
	call scr_addr
	ld a,(lv_class)
	ld e,a
	ld d,0
	push hl
	ld hl,enc_tab
	add hl,de
	ld a,(hl)
	pop hl
	ld e,a
	ld d,a
	ld b,6
	ld c,3
	call fill_cell
	;; name
	ld a,(lv_row)
	ld l,a
	ld h,3
	call TXT_SET_CURSOR
	ld a,(lv_class)
	ld hl,class_short
	call print_nth
	;; count
	ld a,(lv_row)
	ld l,a
	ld h,15
	call TXT_SET_CURSOR
	ld a,(lv_class)
	add a,a
	ld e,a
	ld d,0
	ld hl,cnt_class
	add hl,de
	ld e,(hl)
	inc hl
	ld d,(hl)
	ex de,hl
	call print_dec5
	ld hl,lv_row
	inc (hl)
	pop hl
	jr lv_entry
lv_text:
	ld hl,msg_dstep
	call print_str
	ld a,(dstep)
	cp 2
	ld hl,msg_on
	jr z,lv_ds
	ld hl,msg_off
lv_ds:
	call print_str
	ld hl,msg_t0
	call print_str
	ld a,(t0_minr)
	call print_hex8
	ld a," "
	call TXT_OUTPUT
	ld a,(t0_count)
	call print_dec2
	ld hl,msg_legkeys
	call print_str
	call flush_keys
	call KM_WAIT_CHAR
	ret

;; cnt_class[C]++
lv_inc:
	ld a,c
	and 15
	add a,a
	ld e,a
	ld d,0
	ld hl,cnt_class
	add hl,de
	inc (hl)
	ret nz
	inc hl
	inc (hl)
	ret

legend_order:
	db CL_EMPTY,CL_FILL,CL_DIR,CL_HEADER,CL_TEXT,CL_BINARY,CL_SYSTEM
	db CL_DELETED,CL_SOFT,CL_CRC,CL_IDERR,CL_UNFORM,CL_OTHER,0

msg_legend:	db 31,1,1,"LEGEND       COUNT",255
msg_dstep:	db 31,1,17,"DOUBLE STEP ",255
msg_on:		db "ON",255
msg_off:	db "OFF",255
msg_t0:		db 31,1,18,"TRACK 0: ID &",255
msg_legkeys:
	db 31,1,20,"ARROWS MOVE CURSOR"
	db 31,1,21,"SHIFT+",242,243," 10 TRKS"
	db 31,1,22,"D/ENTER HEX DUMP"
	db 31,1,23,"ESC/M OPTIONS MENU"
	db 31,1,25,"PRESS ANY KEY",255

;; ==========================================================================
;; Hex dump of the sector under the cursor (mode 2).  The sector is read
;; again from the disc.
;; ==========================================================================
dump_view:
	call cursor_pos
	call entry_addr
	ld a,(hl)
	cp TS_OK
	ret nz
	inc hl
	ld b,(hl)
	inc hl
	ld a,(cur_slot)
	cp MAXSLOT
	ret nc
	cp b
	ret nc
	add a,a
	add a,a
	add a,a
	ld e,a
	ld d,0
	add hl,de
	ld (inf_slot),hl

	ld a,2
	call SCR_SET_MODE
	ld hl,msg_reading
	call print_str
	call motor_on
	ld a,(cur_t)
	ld b,a
	ld a,(dstep)
	cp 2
	ld a,b
	jr nz,dv_seek
	add a,a
dv_seek:
	call seek_phys
	ld hl,(inf_slot)
	ld a,(cur_s)
	call fdc_read_sector
	call motor_off
	ld hl,res_buf
	ld de,dv_res
	ld bc,3
	ldir
	ld hl,(rd_count)
	ld (dv_count),hl
	ld a,(res_ok)
	ld (dv_ok),a
	;; length and page count
	ld hl,(inf_slot)
	ld de,SL_N
	add hl,de
	ld a,(hl)
	ld hl,128
	cp 6
	jr c,dv_shift
	ld a,6
dv_shift:
	or a
	jr z,dv_len
	add hl,hl
	dec a
	jr dv_shift
dv_len:
	ld (dv_length),hl
	ld a,h
	or a
	jr nz,dv_pages
	inc a				; 128 bytes: one page
dv_pages:
	ld (dv_npages),a
	xor a
	ld (dv_page),a

dv_show:
	ld a,12				; clear screen
	call TXT_OUTPUT
	;; line 1
	ld hl,msg_dv1
	call print_str
	ld a,(cur_t)
	call print_dec2
	ld hl,msg_dv2
	call print_str
	ld a,(cur_s)
	add a,"0"
	call TXT_OUTPUT
	ld hl,msg_dv3
	call print_str
	ld hl,(inf_slot)
	ld b,4
dv_chrn:
	ld a,(hl)
	call print_hex8
	ld a," "
	call TXT_OUTPUT
	inc hl
	djnz dv_chrn
	ld a,"("
	call TXT_OUTPUT
	ld hl,(dv_length)
	call print_dec
	ld hl,msg_dv4
	call print_str
	;; line 2: status of this read and of the scan
	ld hl,msg_dv5
	call print_str
	ld a,(dv_ok)
	or a
	jr nz,dv_st
	ld hl,msg_timeout
	call print_str
	jr dv_st_done
dv_st:
	ld hl,dv_res
	ld b,3
dv_stl:
	ld a,(hl)
	call print_hex8
	ld a," "
	call TXT_OUTPUT
	inc hl
	djnz dv_stl
dv_st_done:
	ld hl,msg_dv10
	call print_str
	ld hl,(dv_count)
	call print_dec
	ld hl,msg_dv6
	call print_str
	ld hl,(inf_slot)
	call print_class
	;; line 3
	ld hl,msg_dv7
	call print_str
	ld a,(dv_page)
	inc a
	call print_dec2
	ld hl,msg_dv8
	call print_str
	ld a,(dv_npages)
	call print_dec2
	ld hl,msg_dv9
	call print_str
	;; 16 lines of 16 bytes (8 lines for a 128 byte sector)
	ld a,(dv_page)
	ld h,a
	ld l,0
	ld (dv_offset),hl
	ld a,(dv_length+1)
	or a
	ld b,16
	jr nz,dv_lines
	ld b,8
dv_lines:
	ld a,5
	ld (dv_row),a
dv_line:
	push bc
	ld a,(dv_row)
	ld l,a
	ld h,1
	call TXT_SET_CURSOR
	ld hl,(dv_offset)
	call print_hex16
	ld a,":"
	call TXT_OUTPUT
	ld a," "
	call TXT_OUTPUT
	ld hl,(dv_offset)
	ld de,BUFFER
	add hl,de
	push hl
	ld b,16
dv_hex:
	ld a,(hl)
	call print_hex8
	ld a," "
	call TXT_OUTPUT
	inc hl
	djnz dv_hex
	ld a," "
	call TXT_OUTPUT
	pop hl
	ld b,16
dv_asc:
	ld a,(hl)
	cp " "
	jr c,dv_dot
	cp &7f
	jr c,dv_chr
dv_dot:
	ld a,"."
dv_chr:
	call TXT_OUTPUT
	inc hl
	djnz dv_asc
	ld hl,(dv_offset)
	ld de,16
	add hl,de
	ld (dv_offset),hl
	ld hl,dv_row
	inc (hl)
	pop bc
	djnz dv_line

dv_key:
	call KM_WAIT_CHAR
	cp K_ESC
	jr z,dv_exit
	cp K_RIGHT
	jr z,dv_next
	cp K_DOWN
	jr z,dv_next
	cp " "
	jr z,dv_next
	cp K_LEFT
	jr z,dv_prev
	cp K_UP
	jr z,dv_prev
	and &df
	cp "M"
	jr z,dv_exit
	jr dv_key
dv_next:
	ld a,(dv_npages)
	ld b,a
	ld a,(dv_page)
	inc a
	cp b
	jr nc,dv_key
	ld (dv_page),a
	jp dv_show
dv_prev:
	ld a,(dv_page)
	or a
	jr z,dv_key
	dec a
	ld (dv_page),a
	jp dv_show
dv_exit:
	ret

msg_reading:	db 31,1,1,"Reading sector...",255
msg_dv1:	db 31,1,1,"TRACK ",255
msg_dv2:	db "  SIDE ",255
msg_dv3:	db "  ID (C H R N): ",255
msg_dv4:	db " BYTES)",255
msg_dv5:	db 31,1,2,"THIS READ ST0 ST1 ST2: ",255
msg_dv6:	db "  SCAN: ",255
msg_dv10:	db " BYTES READ ",255
msg_dv7:	db 31,1,3,"PAGE ",255
msg_dv8:	db " OF ",255
msg_dv9:	db "   SPACE/ARROWS = PAGE   ESC = BACK TO MAP",255
msg_timeout:	db "TIMEOUT ",255

;; ==========================================================================
;; Printing helpers (all use TXT OUTPUT, which preserves all registers)
;; ==========================================================================

;; print 255 terminated string at HL (control codes are obeyed)
print_str:
	ld a,(hl)
	cp 255
	ret z
	call TXT_OUTPUT
	inc hl
	jr print_str

;; A as two decimal digits (0-99)
print_dec2:
	ld b,"0"-1
pd2_loop:
	inc b
	sub 10
	jr nc,pd2_loop
	add a,10+"0"
	push af
	ld a,b
	call TXT_OUTPUT
	pop af
	jp TXT_OUTPUT

;; HL as decimal, right aligned in 5 characters
print_dec5:
	ld a,1
	jr pd_start
;; HL as decimal, no padding
print_dec:
	xor a
pd_start:
	ld (pd_pad),a
	ld c,0				; set once a digit was printed
	ld de,-10000
	call pd_digit
	ld de,-1000
	call pd_digit
	ld de,-100
	call pd_digit
	ld de,-10
	call pd_digit
	ld a,l
	add a,"0"
	jp TXT_OUTPUT
pd_digit:
	ld a,-1
pd_count:
	inc a
	add hl,de
	jr c,pd_count
	sbc hl,de			; carry is clear: adds the last step back
	or a
	jr nz,pd_nonzero
	bit 0,c
	jr nz,pd_nonzero
	ld a,(pd_pad)
	or a
	ret z
	ld a," "
	jp TXT_OUTPUT
pd_nonzero:
	ld c,1
	add a,"0"
	jp TXT_OUTPUT

;; HL as 4 hex digits
print_hex16:
	ld a,h
	call print_hex8
	ld a,l
;; A as 2 hex digits
print_hex8:
	push af
	rrca
	rrca
	rrca
	rrca
	call ph_nibble
	pop af
ph_nibble:
	and &0f
	add a,"0"
	cp "9"+1
	jr c,ph_out
	add a,7
ph_out:
	jp TXT_OUTPUT

;; empty the keyboard buffer
flush_keys:
	call KM_READ_CHAR
	jr c,flush_keys
	ret

;; ==========================================================================
;; Variables
;; ==========================================================================
saved_sp:	dw 0

;; options (menu)
opt_drive:	db 0		; 0 = A, 1 = B
opt_tracks:	db 0		; 0 auto, 1 = 40, 2 = 42, 3 = 80
opt_sides:	db 0		; 0 auto, 1, 2
opt_retries:	db 2		; 0 - 5

;; disc geometry
n_tracks:	db 40
n_sides:	db 1
dstep:		db 1		; 2 = double step (40 track disc, 80 track drive)
fmt_sys:	db 0		; CP/M system tracks of the format
fmt_tracks:	db 0
fmt_sides:	db 0
fmt_name:	dw fmt_blank+5
t0_count:	db 0		; sectors on track 0 side 0
t0_minr:	db 0		; lowest sector ID on track 0 side 0
st3:		db 0		; SENSE DRIVE STATUS result

;; FDC state
motor_state:	db 0
cur_phys:	db &ff		; physical track under the head (&FF unknown)
sp_target:	db 0
cmd_buf:	ds 9
res_buf:	ds 16
res_count:	db 0
res_ok:		db 0		; 0 = last result timed out
rd_count:	dw 0		; bytes received by the last READ DATA

;; scanning
scan_t:		db 0
scan_s:		db 0
aborted:	db 0
cur_entry:	dw 0
st_nslots:	db 0
st_slot:	db 0
rs_slot:	dw 0
rs_tries:	db 0
rs_class:	db 0
idcount:	db 0
ci_fails:	db 0
ci_nr:		db 0
ci_period:	db 0
so_swapped:	db 0
cl_length:	dw 0
cl_limit:	dw 0
cnt_ok:		dw 0
cnt_bad:	dw 0
cnt_weak:	dw 0
cnt_unf:	db 0

;; screen
enc_tab:	ds 16
cell_w:		db 2
grid_x0:	db 0
slot_h:		db 14
cell_h:		db 12
disp_slots:	db 10
dt_y:		db 0
dt_pat:		db 0
dt_t:		db 0
dt_hgt:		db 0
dcol_ink:	db 0
dc_ink:		db 0
dc_x:		db 0

;; viewer
cur_t:		db 0
cur_s:		db 0
cur_slot:	db 0
inf_slot:	dw 0
cnt_class:	ds 32
lv_row:		db 0
lv_class:	db 0
dv_res:		ds 3
dv_ok:		db 0
dv_count:	dw 0
dv_length:	dw 0
dv_npages:	db 0
dv_page:	db 0
dv_offset:	dw 0
dv_row:		db 0
pd_pad:		db 0

idlist:		ds MAXIDS*5

;; results table: 80 tracks x 2 sides x 130 bytes, page aligned, must end
;; below the sector buffer at &8000
TABLE		equ ($+255)/256*256
TABLE_END	equ TABLE+MAXTRACK*2*ENTRY_SIZE

	end start

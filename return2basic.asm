org &4000
 
; save BASIC registers for return
push af  
push hl
push bc
push de

; start code here...
; BASIC rom calls
Mode			equ &bc0e
PrintChar		equ &bb5a
TextCursor		equ &bb75 ;(h=x,l=y,a=rollcount)
Pen			equ &bb90 ;(in: A=foreground color 0..15)
; main ASM..
main:
	ld a, 1 ; set mode
	call Mode
	ld a,2
	call Pen
	ld hl,Message ; load message string location
	call PrintString	
loop_init:
	ld b,0
loop_cond:
	ld a,10
	cp b
	jp z,loop_end
loop_body:	
	ld a,b
	call Pen
	call NewLine
	ld hl,NewMessage
	call PrintString
loop_next:
	inc b
	jp	loop_cond
loop_end:
	ld a,1
	call Pen
	
; end code here
end:
; load BASIC registers for return
pop de
pop bc
pop hl
pop af

ret ; return to basic

;; functions from main loop here
Locate:
		inc h
		inc l
		call TextCursor 
		ret
NewLine:
		ld a,13 			; carrage return
		call PrintChar
		ld a,10				; line feed
		jp PrintChar
		ret
PrintString:
		ld a,(hl)			; print '255' terminated string
		cp 255
		ret z
		inc hl
		call PrintChar
		jr PrintString

;; tables for functions here...
Message: 	db 'this is a message from ASM!',255
NewMessage:	db 'this is a looped message from ASM!',255

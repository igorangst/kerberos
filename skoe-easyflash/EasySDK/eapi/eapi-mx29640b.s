;
; EasyFlash
;
; (c) 2009-2010 Thomas 'skoe' Giesel
;
; This software is provided 'as-is', without any express or implied
; warranty.  In no event will the authors be held liable for any damages
; arising from the use of this software.
;
; Permission is granted to anyone to use this software for any purpose,
; including commercial applications, and to alter it and redistribute it
; freely, subject to the following restrictions:
;
; 1. The origin of this software must not be misrepresented; you must not
;    claim that you wrote the original software. If you use this software
;    in a product, an acknowledgment in the product documentation would be
;    appreciated but is not required.
; 2. Altered source versions must be plainly marked as such, and must not be
;    misrepresented as being the original software.
; 3. This notice may not be removed or altered from any source distribution.

!source "eapi_defs.s"

FLASH_ALG_ERROR_BIT      = $20

; There's a pointer to our code base
EAPI_ZP_INIT_CODE_BASE   = $4b

; hardware dependend values
MX29LV640EB_NUM_SLOTS    = 8
MX29LV640EB_MFR_ID       = $c2
MX29LV640EB_DEV_ID       = $cb

EAPI_RAM_CODE           = $df80
EAPI_RAM_SIZE           = 124

* = $c000 - 2
        ; PRG start address
        !word $c000

EAPICodeBase:
        !byte $65, $61, $70, $69        ; signature "EAPI"

        !pet "MX29LV640EB 1.2"
        !byte 0                         ; 16 bytes, must be 0-terminated

; =============================================================================
;
; EAPIInit: User API: To be called with JSR <load_address> + 20
;
; Read Manufacturer ID and Device ID from the flash chip(s) and check if this
; chip is supported by this driver. Prepare our private RAM for the other
; functions of the driver.
; When this function returns, EasyFlash will be configured to bank in the ROM
; area at $8000..$bfff.
;
; This function calls SEI, it restores all Flags except C before it returns.
; Do not call it with D-flag set. $01 must enable both ROM areas.
;
; parameters:
;       -
; return:
;       C   set: Flash chip not supported by this driver
;           clear: Flash chip supported by this driver
;       If C is clear:
;       A   Device ID
;       X   Manufacturer ID
;       Y   Number of physical banks (>= 64) or
;           number of slots (< 64) with 64 banks each
;       If C is set:
;       A   Error reason
; changes:
;       all registers are changed
;
; =============================================================================
EAPIInit:
        php
        sei
        ; backup ZP space
        lda EAPI_ZP_INIT_CODE_BASE
        pha
        lda EAPI_ZP_INIT_CODE_BASE + 1
        pha

        ; find out our memory address
        lda #$60        ; rts
        sta EAPI_ZP_INIT_CODE_BASE
        jsr EAPI_ZP_INIT_CODE_BASE
initCodeBase = * - 1
        tsx
        lda $100, x
        sta EAPI_ZP_INIT_CODE_BASE + 1
        dex
        lda $100, x
        sta EAPI_ZP_INIT_CODE_BASE
        clc
        bcc initContinue

RAMCode:
        ; This code will be copied to EasyFlash RAM at EAPI_RAM_CODE
        !pseudopc EAPI_RAM_CODE {
RAMContentBegin:
; =============================================================================
; JUMP TABLE (will be updated to be correct)
; =============================================================================
jmpTable:
        jmp EAPIWriteFlash - initCodeBase
        jmp EAPIEraseSector - initCodeBase
        jmp EAPISetBank - initCodeBase
        jmp EAPIGetBank - initCodeBase
        jmp EAPISetPtr - initCodeBase
        jmp EAPISetLen - initCodeBase
        jmp EAPIReadFlashInc - initCodeBase
        jmp EAPIWriteFlashInc - initCodeBase
        jmp EAPISetSlot - initCodeBase
        jmp EAPIGetSlot - initCodeBase
__EAPIResetFlashJmp: ; private!
        jmp __EAPIResetFlash - initCodeBase ; private!
jmpTableEnd:

; =============================================================================
;
; Internal function
;
; Switch to Ultimax mode, write a byte to flash (complete write sequence),
; return to normal mode.
;
; Must not change the C flag!
;
; Parameters:
;           A = EASYFLASH_IO_FLASH_SETUP
; Changes:
;           X
; Return:
;           A = value which has been written
;
; =============================================================================

writeByte:
            ; bank 0, slot 0 must have been selected
            ; /GAME low, /EXROM high, LED on, no VIC-II
            sta EASYFLASH_IO_CONTROL

            ; cycle 1: write $AA to $AAA
            lda #$aa
            sta $8aaa

            ; cycle 2: write $55 to $555
            lsr
            sta $8555

            ; cycle 3: write $A0 to $AAA
            lda #$a0
            sta $8aaa

            ; now we have to activate the right slot and bank
            lda EAPI_SHADOW_SLOT
            sta EASYFLASH_IO_SLOT
            lda EAPI_SHADOW_BANK
            sta EASYFLASH_IO_BANK

            ; cycle 4: write data
EAPI_WRITE_VAL = * + 1
            lda #00
EAPI_WRITE_ADDR_LO = * + 1
EAPI_WRITE_ADDR_HI = * + 2
            sta $ffff           ; will be modified
exitUltimax:
            ; /GAME low, /EXROM low, LED off
            ldx #EASYFLASH_IO_16K_SETUP
            stx EASYFLASH_IO_CONTROL
            rts


; =============================================================================
;
; Internal function
;
; 1. Turn on Ultimax mode and LED
; 2. Write byte to address
; 3. Turn off Ultimax mode and LED
;    (show 16k of current bank at $8000..$BFFF)
;
; Remember that the address must be based on $8000 for LOROM or
; $E000 for HIROM! Der caller may want to SEI.
;
; Parameters:
;           A   Value
;           XY  Address (X = low)
; Changes:
;           X
;
; =============================================================================
ultimaxWriteXX55:
            ldx #$55
ultimaxWrite:
            stx uwDest
            sty uwDest + 1
            ; /GAME low, /EXROM high, LED on, no VIC-II
            ldx #EASYFLASH_IO_FLASH_SETUP
            stx EASYFLASH_IO_CONTROL
uwDest = * + 1
            sta $ffff           ; will be modified
            jmp exitUltimax


; =============================================================================
;
; Internal function
;
; Read a byte from the inc-address
;
; =============================================================================
readByteForInc:
EAPI_INC_ADDR_LO = * + 1
EAPI_INC_ADDR_HI = * + 2
            lda $ffff
            rts


; =============================================================================
;
; Internal function
;
; Used for progress check. Compare A with the value from (YX).
;
; =============================================================================
cmpByte:                            ;  6  6 (JSR)
EAPI_CMP_BYTE_ADDR_LO = * + 1
EAPI_CMP_BYTE_ADDR_HI = * + 2
            cmp $ffff               ; +4 10
            rts                     ; +6 25


; =============================================================================
; Variables
; =============================================================================

EAPI_TMP_VAL1           = * + 0
EAPI_TMP_VAL2           = * + 1
EAPI_TMP_VAL3           = * + 2
EAPI_TMP_VAL4           = * + 3
EAPI_TMP_VAL5           = * + 4
EAPI_SHADOW_BANK        = * + 5 ; copy of current bank number set by the user
EAPI_INC_TYPE           = * + 6 ; type used for EAPIReadFlashInc/EAPIWriteFlashInc
EAPI_LENGTH_LO          = * + 7
EAPI_LENGTH_MED         = * + 8
EAPI_LENGTH_HI          = * + 9
EAPI_SHADOW_SLOT        = * + 10
; =============================================================================
RAMContentEnd           = * + 11
        } ; end pseudopc
RAMCodeEnd:

!if RAMContentEnd - RAMContentBegin > EAPI_RAM_SIZE {
    !error "Code too large"
}

!if * - initCodeBase > 256 {
    !error "RAMCode not addressable trough (initCodeBase),y"
}

initContinue:
        ; *** copy some code to EasyFlash private RAM ***
        ; length of data to be copied
        ldx #RAMCodeEnd - RAMCode - 1
        ; offset behind initCodeBase of last byte to be copied
        ldy #RAMCodeEnd - initCodeBase - 1
cidCopyCode:
        lda (EAPI_ZP_INIT_CODE_BASE),y
        sta EAPI_RAM_CODE, x
        cmp EAPI_RAM_CODE, x    ; check if there's really RAM at this address
        bne ciRamError
        dey
        dex
        bpl cidCopyCode

        ; *** calculate jump table ***
        ldx #0
cidFillJMP:
        inx
        clc
        lda jmpTable, x
        adc EAPI_ZP_INIT_CODE_BASE
        sta jmpTable, x
        inx
        lda jmpTable, x
        adc EAPI_ZP_INIT_CODE_BASE + 1
        sta jmpTable, x
        inx
        cpx #jmpTableEnd - jmpTable
        bne cidFillJMP
        clc
        bcc ciNoRamError
ciRamError:
        lda #EAPI_ERR_RAM
        sta EAPI_TMP_VAL2
        sec                     ; error
ciNoRamError:
        ; restore the caller's ZP state
        pla
        sta EAPI_ZP_INIT_CODE_BASE + 1
        pla
        sta EAPI_ZP_INIT_CODE_BASE
        bcs returnOnly

        ; *** start of flash detection ***
        ; check for M29F160ET

        ; backup slot
        lda EASYFLASH_IO_SLOT
        sta EAPI_SHADOW_SLOT

        ; select slot 0 / bank 0
        lda #0
        sta EASYFLASH_IO_SLOT
        sta EASYFLASH_IO_BANK

        ; cycle 1: write $AA to $AAA
        ldx #<$8aaa
        ldy #>$8aaa
        lda #$aa
        jsr ultimaxWrite

        ; cycle 2: write $55 to $555
        ldx #<$8555
        ldy #>$8555
        lsr
        jsr ultimaxWrite

        ; cycle 3: write $90 to $aaa
        ldx #<$8aaa
        ldy #>$8aaa
        lda #$90
        jsr ultimaxWrite

        ; offset 0: Manufacturer ID (we're on bank 0)
        ldx $8000
        stx EAPI_TMP_VAL1

        ; offset 2: Device ID
        lda $8002
        sta EAPI_TMP_VAL2

        ; check if it is an MX29LV640EB
        cpx #MX29LV640EB_MFR_ID
        bne ciNotSupported
        cmp #MX29LV640EB_DEV_ID
        bne ciNotSupported

        ; everything okay
        clc
        bcc resetAndReturn

ciNotSupported:
        lda #EAPI_ERR_ROML
        sta EAPI_TMP_VAL2       ; error code in A
        sec

resetAndReturn:
        ; reset flash chip: write $F0 to any address
        ; ldx #<$8000 - don't care
        ldy #>$8000
        lda #$f0
        jsr ultimaxWrite

returnOnly:                     ; C indicates error
        lda EAPI_SHADOW_SLOT
        sta EASYFLASH_IO_SLOT   ; restore slot

        lda EAPI_TMP_VAL2       ; device or error code in A
        bcs returnCSet
        ldx EAPI_TMP_VAL1       ; manufacturer in X
        ldy #MX29LV640EB_NUM_SLOTS ; number of slots in Y

        plp
        clc                     ; do this after plp :)
        rts
returnCSet:
        plp
        sec                     ; do this after plp :)
        rts

; =============================================================================
;
; EAPIWriteFlash: User API: To be called with JSR jmpTable + 0 = $df80
;
; Write a byte to the given address. The address must be as seen in Ultimax
; mode, i.e. do not use the base addresses $8000 or $a000 but $8000 or $e000.
;
; When writing to flash memory only bits containing a '1' can be changed to
; contain a '0'. Trying to change memory bits from '0' to '1' will result in
; an error. You must erase a memory block to get '1' bits.
;
; This function uses SEI, it restores all flags except C before it returns.
; Do not call it with D-flag set. $01 must enable both ROM areas.
; It can only be used after having called EAPIInit.
;
; parameters:
;       A   value
;       XY  address (X = low), $8xxx/$9xxx or $Exxx/$Fxxx
;
; return:
;       C   set: Error
;           clear: Okay
; changes:
;       Z,N <- value
;
; =============================================================================
EAPIWriteFlash:
        sta EAPI_WRITE_VAL
        stx EAPI_WRITE_ADDR_LO
        stx EAPI_CMP_BYTE_ADDR_LO
        sty EAPI_WRITE_ADDR_HI
        php
        sei

        ; backup slot
        lda EASYFLASH_IO_SLOT
        sta EAPI_SHADOW_SLOT

        ; select slot 0 / bank 0
        lda #0
        sta EASYFLASH_IO_SLOT
        sta EASYFLASH_IO_BANK

        tya
        and #$bf            ; $ex => $ax
        sta EAPI_CMP_BYTE_ADDR_HI

        lda #EASYFLASH_IO_FLASH_SETUP
        jsr writeByte
wcpCheck:
        ; that's it, check result
        ; EAPI_WRITE_VAL still in A
        ldx #20
wcpLoop:
        jsr cmpByte
        beq wcheckOK
        dex
        bne wcpLoop
        ; Time out and/or error
        jmp __EAPIResetFlashJmp
wcheckOK:
        plp
        clc
        ldy EAPI_WRITE_ADDR_HI
        ldx EAPI_WRITE_ADDR_LO
        ; EAPI_WRITE_VAL still in A <= wirklich?
        rts


; =============================================================================
;
; EAPIEraseSector: User API: To be called with JSR jmpTable + 3 = $df83
;
; Erase the sector at the given address. The bank number currently set and the
; address together must point to the first byte of a 64 kByte sector.
;
; When erasing a sector, all bits of the 64 KiB area will be set to '1'.
; This means that 8 banks with 8 KiB each will be erased, all of them either
; in the LOROM chip when $8000 is used or in the HIROM chip when $e000 is
; used.
;
; This function uses SEI, it restores all flags except C before it returns.
; Do not call it with D-flag set. $01 must enable the affected ROM area.
; It can only be used after having called EAPIInit.
;
; Special feature for this flash which has 8 * 8 KiByte boot sectors:
; When bank 0 is erased, all of these 8 sectors are erased automatically.
; The 8 KiByte sectors 1 to 7 can be erased independently too.
;
; parameters:
;       A   bank
;       Y   base address (high byte), $80 for LOROM, $a0 or $e0 for HIROM
;
; return:
;       C   set: Error
;           clear: Okay
;
; change:
;       Z,N <- bank
;
; =============================================================================
EAPIEraseSector:
        sta EAPI_WRITE_VAL      ; used for bank number here
        stx EAPI_WRITE_ADDR_LO  ; backup of X only, no parameter
        sty EAPI_WRITE_ADDR_HI
        php
        ldx EAPI_SHADOW_SLOT    ; slot 0?
        bne seNormal
        cmp #0          ; bank 0?
        bne seNormal
        cpy #$80        ; ROML?
        bne seNormal
        plp
        ; when we are here they try to erase 00:0:0000
        ; there are 8 * 8 kByte boot blocks there, we erase all of them
        ldx #7
seEraseBootBlocks:
        txa
        jsr jmpTable + 3 ; EAPIEraseSector
        bcc sebbOK
        lda #0
        sta EAPI_WRITE_VAL ; restore original backup of A=0
        jmp __EAPIResetFlashJmp
sebbOK:
        dex
        bne seEraseBootBlocks
        txa
        sta EAPI_WRITE_VAL ; restores original backup of A=0
        php
seNormal:
        sei

        ; backup slot
        lda EASYFLASH_IO_SLOT
        sta EAPI_SHADOW_SLOT

        ; select slot 0 / bank 0
        lda #0
        sta EASYFLASH_IO_SLOT
        sta EASYFLASH_IO_BANK

        ; cycle 1: write $AA to $AAA
        ldx #<$8aaa
        ldy #>$8aaa
        lda #$aa
        jsr ultimaxWrite

        ; cycle 2: write $55 to $555
        ldx #<$8555
        ldy #>$8555
        lsr
        jsr ultimaxWrite

        ; cycle 3: write $80 to $AAA
        ldx #<$8aaa
        ldy #>$8aaa
        lda #$80
        jsr ultimaxWrite

        ; cycle 4: write $AA to $AAA
        ldx #<$8aaa
        ldy #>$8aaa
        lda #$aa
        jsr ultimaxWrite

        ; cycle 5: write $55 to $555
        ldx #<$8555
        ldy #>$8555
        lda #$55
        jsr ultimaxWrite

        ; activate the right slot and bank
        lda EAPI_SHADOW_SLOT
        sta EASYFLASH_IO_SLOT
        lda EAPI_WRITE_VAL
        sta EASYFLASH_IO_BANK

        ldx #$00
        stx EAPI_CMP_BYTE_ADDR_LO

        ; cycle 6: write $30 to base + SA
        ldy EAPI_WRITE_ADDR_HI
        tya
        cmp #$80
        beq seskip
        ldy #$e0 ; $a0 => $e0
        lda #$a0
seskip:
        sta EAPI_CMP_BYTE_ADDR_HI
        lda #$30
        jsr ultimaxWrite

; =============================================================================
;
; Check the progress. To do this, read the value at (YX) until it matches
; A or until a timer counter expires.
;
; If the timer expires, reset the flash chips and return an error indication.
; Otherwise return OK.
;
; As long as an operation is not complete or was cancelled because of an error,
; DQ can never be the expected value, as it contains a complement bit.
; As it seems that we can't read the toggle bit reliably on all hardware
; (read glitches?), we use this way to check the progress.
;
; =============================================================================
        lda #$ff            ; check value
        tax
        tay                 ; timer
ecpLoop:
        jsr cmpByte
        beq ecpOK
        dex
        bne ecpLoop
        dey
        bne ecpLoop
        ; Time out and/or error
        jmp __EAPIResetFlashJmp
ecpOK:
        plp
        clc
        ldy EAPI_WRITE_ADDR_HI
        ldx EAPI_WRITE_ADDR_LO
        lda EAPI_WRITE_VAL
        rts

; =============================================================================
;
; Reset flash and return error.
;
; =============================================================================
__EAPIResetFlash:
        lda EAPI_SHADOW_BANK
        sta EASYFLASH_IO_BANK

        ; ldx #<$8000 - don't care
        ldy #>$8000
        lda #$f0
        jsr ultimaxWrite

        plp
        sec ; error
        ldy EAPI_WRITE_ADDR_HI
        ldx EAPI_WRITE_ADDR_LO
        lda EAPI_WRITE_VAL
        rts

; =============================================================================
;
; EAPISetBank: User API: To be called with JSR jmpTable + 6 = $df86
;
; Set the bank. This will take effect immediately for cartridge read access
; and will be used for the next flash write or read command.
;
; This function can only be used after having called EAPIInit.
;
; parameters:
;       A   bank
;
; return:
;       -
;
; changes:
;       -
;
; =============================================================================
EAPISetBank:
        sta EAPI_SHADOW_BANK
        sta EASYFLASH_IO_BANK
        rts


; =============================================================================
;
; EAPIGetBank: User API: To be called with JSR jmpTable + 9 = $df89
;
; Get the selected bank which has been set with EAPISetBank.
; Note that the current bank number can not be read back using the hardware
; register $de00 directly, this function uses a mirror of that register in RAM.
;
; This function can only be used after having called EAPIInit.
;
; parameters:
;       -
;
; return:
;       A  bank
;
; changes:
;       Z,N <- bank
;
; =============================================================================
EAPIGetBank:
        lda EAPI_SHADOW_BANK
        rts


; =============================================================================
;
; EAPISetPtr: User API: To be called with JSR jmpTable + 12 = $df8c
;
; Set the pointer for EAPIReadFlashInc/EAPIWriteFlashInc.
;
; This function can only be used after having called EAPIInit.
;
; parameters:
;       A   bank mode, where to continue at the end of a bank
;           $D0: 00:0:1FFF=>00:1:0000, 00:1:1FFF=>01:0:1FFF (lhlh...)
;           $B0: 00:0:1FFF=>01:0:0000 (llll...)
;           $D4: 00:1:1FFF=>01:1:0000 (hhhh...)
;       XY  address (X = low) address must be in range $8000-$bfff
;
; return:
;       -
;
; changes:
;       -
;
; =============================================================================
EAPISetPtr:
        sta EAPI_INC_TYPE
        stx EAPI_INC_ADDR_LO
        sty EAPI_INC_ADDR_HI
        rts


; =============================================================================
;
; EAPISetLen: User API: To be called with JSR jmpTable + 15 = $df8f
;
; Set the number of bytes to be read with EAPIReadFlashInc.
;
; This function can only be used after having called EAPIInit.
;
; parameters:
;       XYA length, 24 bits (X = low, Y = med, A = high)
;
; return:
;       -
;
; changes:
;       -
;
; =============================================================================
EAPISetLen:
        stx EAPI_LENGTH_LO
        sty EAPI_LENGTH_MED
        sta EAPI_LENGTH_HI
        rts


; =============================================================================
;
; EAPIReadFlashInc: User API: To be called with JSR jmpTable + 18 = $df92
;
; Read a byte from the current pointer from EasyFlash flash memory.
; Increment the pointer according to the current bank wrap strategy.
; Pointer and wrap strategy have been set by a call to EAPISetPtr.
;
; The number of bytes to be read may be set by calling EAPISetLen.
; EOF will be set if the length is zero, otherwise it will be decremented.
; Even when EOF is delivered a new byte has been read and the pointer
; incremented. This means the use of EAPISetLen is optional.
;
; This function can only be used after having called EAPIInit.
;
; parameters:
;       -
;
; return:
;       A   value
;       C   set if EOF
;
; changes:
;       Z,N <- value
;
; =============================================================================
EAPIReadFlashInc:
        ; now we have to activate the right bank
        lda EAPI_SHADOW_BANK
        sta EASYFLASH_IO_BANK

        ; call the read-routine
        jsr readByteForInc

        ; remember the result & x/y registers
        sta EAPI_WRITE_VAL
        stx EAPI_TMP_VAL1
        sty EAPI_TMP_VAL2

        ; make sure that the increment subroutine of the
        ; write routine jumps back to us, and call it
        lda #$00
        sta EAPI_WRITE_ADDR_HI
        beq rwInc_inc

readInc_Length:
        ; decrement length
        lda EAPI_LENGTH_LO
        bne readInc_nomed
        lda EAPI_LENGTH_MED
        bne readInc_nohi
        lda EAPI_LENGTH_HI
        beq readInc_eof
        dec EAPI_LENGTH_HI
readInc_nohi:
        dec EAPI_LENGTH_MED
readInc_nomed:
        dec EAPI_LENGTH_LO
        ;clc ; no EOF - already set by rwInc_noInc
        bcc rwInc_return

readInc_eof:
        sec ; EOF
        bcs rwInc_return


; =============================================================================
;
; EAPIWriteFlashInc: User API: To be called with JSR jmpTable + 21 = $df95
;
; Write a byte to the current pointer to EasyFlash flash memory.
; Increment the pointer according to the current bank wrap strategy.
; Pointer and wrap strategy have been set by a call to EAPISetPtr.
;
; In case of an error the position is not inc'ed.
;
; This function can only be used after having called EAPIInit.
;
; parameters:
;       A   value
;
; return:
;       C   set: Error
;           clear: Okay
; changes:
;       Z,N <- value
;
; =============================================================================
EAPIWriteFlashInc:
        sta EAPI_WRITE_VAL
        stx EAPI_TMP_VAL1
        sty EAPI_TMP_VAL2

        ; load address to store to
        ldx EAPI_INC_ADDR_LO
        lda EAPI_INC_ADDR_HI
        cmp #$a0
        bcc writeInc_skip
        ora #$40 ; $a0 => $e0
writeInc_skip:
        tay
        lda EAPI_WRITE_VAL

        ; write to flash
        jsr jmpTable + 0
        bcs rwInc_return

        ; the increment code is used by both functions
rwInc_inc:
        ; inc to next position
        inc EAPI_INC_ADDR_LO
        bne rwInc_noInc

        ; inc page
        inc EAPI_INC_ADDR_HI
        lda EAPI_INC_TYPE
        and #$e0
        cmp EAPI_INC_ADDR_HI
        bne rwInc_noInc
        ; inc bank
        lda EAPI_INC_TYPE
        asl
        asl
        asl
        sta EAPI_INC_ADDR_HI
        inc EAPI_SHADOW_BANK

rwInc_noInc:
        ; no errors here, clear carry
        clc
        ; readInc: value has be set to zero, so jump back
        ; writeInc: value ist set by EAPIWriteFlash to the HI address (never zero)
        lda EAPI_WRITE_ADDR_HI
        beq readInc_Length
rwInc_return:
        ldy EAPI_TMP_VAL2
        ldx EAPI_TMP_VAL1
        lda EAPI_WRITE_VAL
        rts

; =============================================================================
;
; EAPISetSlot: User API: To be called with JSR jmpTable + 24 = $df98
;
; Set the slot. This function is only available if EAPIInit reported
; multiple slots.
;
; Software which does not need to change the slot number should not need to
; us this function. So usually only EasyProg or similar programs need to call
; this.
;
; This will take effect immediately for cartridge read access
; and will be used for the next flash write or read command.
;
; This function can only be used after having called EAPIInit.
;
; parameters:
;       A   slot
;
; return:
;       -
;
; changes:
;       -
;
; =============================================================================
EAPISetSlot:
        sta EAPI_SHADOW_SLOT
        sta EASYFLASH_IO_SLOT
        rts

; =============================================================================
;
; EAPIGetSlot: User API: To be called with JSR jmpTable + 27 = $df9b
;
; Get the selected slot which has been set with EAPISetSlot. This function is
; only available if EAPIInit reported multiple slots.
;
; Software which does not need to know the slot number should not use this
; function. So usually only EasyProg or similar programs need to call this.
;
; This function can only be used after having called EAPIInit.
;
; parameters:
;       -
;
; return:
;       A  slot
;
; changes:
;       Z,N <- slot
;
; =============================================================================
EAPIGetSlot:
        lda EAPI_SHADOW_SLOT
        rts

; =============================================================================
; We pad the file to the maximal driver size ($0300) to make sure nobody
; has the idea to use the memory behind EAPI in a cartridge. EasyProg
; replaces EAPI and would overwrite everything in this space.
!fill $0300 - (* - EAPICodeBase), $ff
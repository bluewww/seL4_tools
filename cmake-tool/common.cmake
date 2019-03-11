#
# Copyright 2017, Data61
# Commonwealth Scientific and Industrial Research Organisation (CSIRO)
# ABN 41 687 119 230.
#
# This software may be distributed and modified according to the terms of
# the BSD 2-Clause license. Note that NO WARRANTY is provided.
# See "LICENSE_BSD2.txt" for details.
#
# @TAG(DATA61_BSD)
#

cmake_minimum_required(VERSION 3.8.2)

include("${CMAKE_CURRENT_LIST_DIR}/helpers/application_settings.cmake")
include("${CMAKE_CURRENT_LIST_DIR}/helpers/cakeml.cmake")
include("${CMAKE_CURRENT_LIST_DIR}/helpers/cross_compiling.cmake")
include("${CMAKE_CURRENT_LIST_DIR}/helpers/external-project-helpers.cmake")
include("${CMAKE_CURRENT_LIST_DIR}/helpers/rust.cmake")
include("${CMAKE_CURRENT_LIST_DIR}/helpers/dts.cmake")
include("${CMAKE_CURRENT_LIST_DIR}/helpers/simulation.cmake")

# Helper function for modifying the linker flags of a target to set the entry point as _sel4_start
function(SetSeL4Start target)
    set_property(TARGET ${target} APPEND_STRING PROPERTY LINK_FLAGS " -u _sel4_start -e _sel4_start ")
endfunction(SetSeL4Start)

if(KernelSel4ArchIA32)
    set(LinkOFormat "elf32-i386")
elseif(KernelSel4ArchX86_64)
    set(LinkOFormat "elf64-x86-64")
elseif(KernelSel4ArchAarch32 OR KernelSel4ArchArmHyp)
    set(LinkOFormat "elf32-littlearm")
elseif(KernelSel4ArchAarch64)
    set(LinkOFormat "elf64-littleaarch64")
elseif(KernelSel4ArchRiscV32)
    set(LinkOFormat "elf32-littleriscv")
elseif(KernelSel4ArchRiscV64)
    set(LinkOFormat "elf64-littleriscv")
endif()

# Checks the existence of an argument to cpio -o.
# flag refers to a variable in the parent scope that contains the argument, if
# the argument isn't supported then the flag is set to the empty string in the parent scope.
function(CheckCPIOArgument flag)
    file(WRITE ${CMAKE_CURRENT_BINARY_DIR}/cpio-testfile "Testfile contents")
    execute_process(COMMAND bash -c "echo cpio-testfile | cpio ${${flag}} -o"
        WORKING_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}
        OUTPUT_QUIET
        ERROR_QUIET
        RESULT_VARIABLE result)
    if(result)
        set(${flag} "" PARENT_SCOPE)
    endif()
    file(REMOVE ${CMAKE_CURRENT_BINARY_DIR}/cpio-testfile)
endfunction()

# Function for declaring rules to build a cpio archive that can be linked
# into another target
function(MakeCPIO output_name input_files)
    cmake_parse_arguments(PARSE_ARGV 2 MAKE_CPIO "" "CPIO_SYMBOL" "DEPENDS")
    if (NOT "${MAKE_CPIO_UNPARSED_ARGUMENTS}" STREQUAL "")
        message(FATAL_ERROR "Unknown arguments to MakeCPIO")
    endif()
    set(archive_symbol "_cpio_archive")
    if (NOT "${MAKE_CPIO_CPIO_SYMBOL}" STREQUAL "")
        set(archive_symbol ${MAKE_CPIO_CPIO_SYMBOL})
    endif()
    # Check that the reproducible flag is available. Don't use it if it isn't.
    set(reproducible_flag "--reproducible")
    CheckCPIOArgument(reproducible_flag)
    set(append "")
    foreach(file IN LISTS input_files)
        # Try and generate reproducible cpio meta-data as we do this:
        # - touch -d @0 file sets the modified time to 0
        # - --owner=root:root sets user and group values to 0:0
        # - --reproducible creates reproducible archives with consistent inodes and device numbering
        list(APPEND commands
            "bash;-c;cd `dirname ${file}` && mkdir -p temp && cd temp && cp -a ${file} . && touch -d @0 `basename ${file}` && echo `basename ${file}` | cpio ${append} ${reproducible_flag} --owner=root:root --quiet -o -H newc --file=${CMAKE_CURRENT_BINARY_DIR}/archive.${output_name}.cpio && rm `basename ${file}` && cd ../ && rmdir temp;&&"
        )
        set(append "--append")
    endforeach()
    list(APPEND commands "true")

    # RiscV doesn't support linking with -r
    set(relocate "-r")
    if(KernelArchRiscV)
        set(relocate "")
    endif()
    add_custom_command(OUTPUT ${output_name}
        COMMAND rm -f archive.${output_name}.cpio
        COMMAND ${commands}
        COMMAND echo "SECTIONS { ._archive_cpio : ALIGN(4) { ${archive_symbol} = . ; *(.*) ; ${archive_symbol}_end = . ; } }"
            > link.${output_name}.ld
        COMMAND ${CROSS_COMPILER_PREFIX}ld -T link.${output_name}.ld --oformat ${LinkOFormat} ${relocate} -b binary archive.${output_name}.cpio -o ${output_name}
        BYPRODUCTS archive.${output_name}.cpio link.${output_name}.ld
        DEPENDS ${input_files} ${MAKE_CPIO_DEPENDS}
        VERBATIM
        COMMENT "Generate CPIO archive ${output_name}"
    )
endfunction(MakeCPIO)

# We need to the real non symlinked list path in order to find the linker script that is in
# the common-tool directory
get_filename_component(real_list "${CMAKE_CURRENT_LIST_DIR}" REALPATH)

function(DeclareRootserver rootservername)
    SetSeL4Start(${rootservername})
    set_property(TARGET ${rootservername} APPEND_STRING PROPERTY LINK_FLAGS " -T ${real_list}/tls_rootserver.lds ")
    if("${KernelArch}" STREQUAL "x86")
        set(IMAGE_NAME "${CMAKE_BINARY_DIR}/images/${rootservername}-image-${KernelSel4Arch}-${KernelPlatform}")
        set(KERNEL_IMAGE_NAME "${CMAKE_BINARY_DIR}/images/kernel-${KernelSel4Arch}-${KernelPlatform}")
        # Declare targets for building the final kernel image
        if(Kernel64)
            add_custom_command(
                OUTPUT "${KERNEL_IMAGE_NAME}"
                COMMAND ${CROSS_COMPILER_PREFIX}objcopy -O elf32-i386 $<TARGET_FILE:kernel.elf> "${KERNEL_IMAGE_NAME}"
                VERBATIM
                DEPENDS kernel.elf
                COMMENT "objcopy kernel into bootable elf"
            )
        else()
            add_custom_command(
                OUTPUT "${KERNEL_IMAGE_NAME}"
                COMMAND cp $<TARGET_FILE:kernel.elf> "${KERNEL_IMAGE_NAME}"
                VERBATIM
                DEPENDS kernel.elf
            )
        endif()
        add_custom_command(OUTPUT "${IMAGE_NAME}"
            COMMAND cp $<TARGET_FILE:${rootservername}> "${IMAGE_NAME}"
            DEPENDS ${rootservername}
        )
        add_custom_target(rootserver_image ALL DEPENDS "${IMAGE_NAME}" "${KERNEL_IMAGE_NAME}" kernel.elf $<TARGET_FILE:${rootservername}> ${rootservername})
    elseif("${KernelArch}" STREQUAL "arm")
        set(IMAGE_NAME "${CMAKE_BINARY_DIR}/images/${rootservername}-image-arm-${KernelPlatform}")
        set(binary_efi_list "binary;efi")
        if(${ElfloaderImage} IN_LIST binary_efi_list)
            # If not an elf we construct an intermediate rule to do an objcopy to binary
            add_custom_command(OUTPUT "${IMAGE_NAME}"
                COMMAND ${CROSS_COMPILER_PREFIX}objcopy -O binary $<TARGET_FILE:elfloader> "${IMAGE_NAME}"
                DEPENDS $<TARGET_FILE:elfloader> elfloader
            )
        elseif("${ElfloaderImage}" STREQUAL "uimage")
            # Add custom command for converting to uboot image
            add_custom_command(OUTPUT "${IMAGE_NAME}"
            COMMAND mkimage  -A arm64 -O qnx -T kernel -C none -a $<TARGET_PROPERTY:elfloader,PlatformEntryAddr> -e $<TARGET_PROPERTY:elfloader,PlatformEntryAddr> -d $<TARGET_FILE:elfloader> "${IMAGE_NAME}"
            DEPENDS $<TARGET_FILE:elfloader> elfloader
            )
        else()
            add_custom_command(OUTPUT "${IMAGE_NAME}"
                COMMAND ${CMAKE_COMMAND} -E copy $<TARGET_FILE:elfloader> "${IMAGE_NAME}"
                DEPENDS $<TARGET_FILE:elfloader> elfloader
            )
        endif()
        add_custom_target(rootserver_image ALL DEPENDS "${IMAGE_NAME}" elfloader ${rootservername})
        # Set the output name for the rootserver instead of leaving it to the generator. We need
        # to do this so that we can put the rootserver image name as a property and have the
        # elfloader pull it out using a generator expression, since generator expression cannot
        # nest (i.e. in the expansion of $<TARGET_FILE:tgt> 'tgt' cannot itself be a generator
        # expression. Nor can a generator expression expand to another generator expression and
        # get expanded again. As a result we just fix the output name and location of the rootserver
        set_property(TARGET "${rootservername}" PROPERTY OUTPUT_NAME "${rootservername}")
        get_property(rootimage TARGET "${rootservername}" PROPERTY OUTPUT_NAME)
        get_property(dir TARGET "${rootservername}" PROPERTY BINARY_DIR)
        set_property(TARGET rootserver_image PROPERTY ROOTSERVER_IMAGE "${dir}/${rootimage}")
    elseif(KernelArchRiscV)
        set(IMAGE_NAME "${CMAKE_BINARY_DIR}/images/${rootservername}-image-riscv-${KernelPlatform}")
        # On RISC-V we need to package up our final elf image into the Berkeley boot loader
        # which is what the following custom command is achieving

        # TODO: Currently we do not support native RISC-V builds, because there
        # is no native environment to test this. Thus CROSS_COMPILER_PREFIX is
        # always set and the BBL build below uses it to create the
        # "--host=..." parameter. For now, make the build fail if
        # CROSS_COMPILER_PREFIX if not set. It seems that native builds can
        # simply omit the host parameter.
        if("${CROSS_COMPILER_PREFIX}" STREQUAL "")
            message(FATAL_ERROR "CROSS_COMPILER_PREFIX not set.")
        endif()

        # Get host string which is our cross compiler minus the trailing '-'
        string(REGEX REPLACE "^(.*)-$" "\\1" host ${CROSS_COMPILER_PREFIX})
        get_filename_component(host ${host} NAME)
        if(KernelSel4ArchRiscV32)
            set(march rv32imafdc)
        else()
            set(march rv64imafdc)
        endif()
        add_custom_command(OUTPUT "${IMAGE_NAME}"
            COMMAND mkdir -p ${CMAKE_BINARY_DIR}/bbl
            COMMAND cd ${CMAKE_BINARY_DIR}/bbl &&
                    ${BBL_PATH}/configure --quiet
                    --host=${host}
                    --with-arch=${march}
                    --with-payload=$<TARGET_FILE:elfloader> &&
                    make -s clean && make -s > /dev/null
            COMMAND cp ${CMAKE_BINARY_DIR}/bbl/bbl ${IMAGE_NAME}
            DEPENDS $<TARGET_FILE:elfloader> elfloader
            )
        add_custom_target(rootserver_image ALL DEPENDS "${IMAGE_NAME}" elfloader ${rootservername})
        set_property(TARGET "${rootservername}" PROPERTY OUTPUT_NAME "${rootservername}")
        get_property(rootimage TARGET "${rootservername}" PROPERTY OUTPUT_NAME)
        get_property(dir TARGET "${rootservername}" PROPERTY BINARY_DIR)
        set_property(TARGET rootserver_image PROPERTY ROOTSERVER_IMAGE "${dir}/${rootimage}")
    else()
        message(FATAL_ERROR "Unsupported architecture.")
    endif()
    # Store the image and kernel image as properties
    # We use relative paths to the build directory
    file(RELATIVE_PATH IMAGE_NAME_REL ${CMAKE_BINARY_DIR} ${IMAGE_NAME})
    if (NOT "${KERNEL_IMAGE_NAME}" STREQUAL "")
        file(RELATIVE_PATH KERNEL_IMAGE_NAME_REL ${CMAKE_BINARY_DIR} ${KERNEL_IMAGE_NAME})
    endif()
    set_property(TARGET rootserver_image PROPERTY IMAGE_NAME "${IMAGE_NAME_REL}")
    set_property(TARGET rootserver_image PROPERTY KERNEL_IMAGE_NAME "${KERNEL_IMAGE_NAME_REL}")
endfunction(DeclareRootserver)

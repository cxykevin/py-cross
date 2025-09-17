# 使用 Alpine Linux 的 ARMv7 基础镜像
FROM alpine/armv7:latest

# 1. 安装编译 Python 所需的依赖，以及用户之前要求的 tcl/tk 和 sqlite-dev
# build-base 包含了 gcc、make 等基本编译工具
# linux-headers 用于编译一些 Python 模块
# libffi-dev, openssl-dev, bzip2-dev, zlib-dev, readline-dev, gdbm-dev, ncurses-dev 是 Python 常用模块的依赖
# sqlite-dev, tcl-dev, tk-dev 是用户要求的开发包
# xz-dev 用于解压 .tar.xz 格式的 Python 源代码
# wget 用于下载源代码
# ncurses-dev 是 readline-dev 的依赖
# patchelf 用于修改 ELF 文件的 RPATH
RUN apk update && \
    apk add --no-cache \
    build-base \
    linux-headers \
    libffi-dev \
    openssl-dev \
    bzip2-dev \
    zlib-dev \
    readline-dev \
    ncurses-dev \
    gdbm-dev \
    sqlite-dev \
    tcl-dev \
    tk-dev \
    xz-dev \
    wget \
    patchelf \
    && rm -rf /var/cache/apk/*

# 2. 定义 Python 版本
# 更新为 Python 3.13.7
ENV PYTHON_VERSION=3.13.7
ENV PYTHON_MAJOR_MINOR=3.13

# 3. 下载、解压、配置、编译和安装 Python
WORKDIR /tmp
RUN echo "Downloading Python-$PYTHON_VERSION.tar.xz..." && \
    wget https://www.python.org/ftp/python/$PYTHON_VERSION/Python-$PYTHON_VERSION.tar.xz && \
    echo "Extracting Python-$PYTHON_VERSION.tar.xz..." && \
    tar -xf Python-$PYTHON_VERSION.tar.xz && \
    cd Python-$PYTHON_VERSION && \
    echo "Configuring Python build..." && \
    # 配置编译选项。
    # --prefix=/mnt/us/python313: 将 Python 安装到 /mnt/us/python313 目录。
    # --enable-optimizations: 启用 PGO (Profile Guided Optimizations) 和 LTO (Link Time Optimizations)。
    # --with-lto: 启用链接时优化。
    # --with-computed-gotos: 启用计算 goto，提高解释器性能。
    # --enable-shared: 编译共享库 (libpythonX.Y.so)。
    # --with-system-ffi: 使用系统安装的 libffi。
    # --with-system-expat: 使用系统安装的 expat。
    # --with-tcltk: 启用 Tcl/Tk 支持。
    # --with-sqlite3: 启用 SQLite3 支持。
    ./configure --prefix=/mnt/us/python313 \
                --enable-optimizations \
                --with-lto \
                --with-computed-gotos \
                --enable-shared \
                --with-system-ffi \
                --with-system-expat \
                --with-tcltk \
                --with-sqlite3 \
                && \
    echo "Compiling Python (this may take a while)..." && \
    make -j$(nproc) && \
    echo "Installing Python..." && \
    make install && \
    # 清理构建文件和源代码以减小镜像大小
    cd /tmp && \
    rm -rf Python-$PYTHON_VERSION Python-$PYTHON_VERSION.tar.xz && \
    echo "Python $PYTHON_VERSION installed successfully to /mnt/us/python313."

# 4. 收集所有共享库并复制到 /mnt/us/python313/lib 目录
#    并调整 RPATH，使其在安装目录内找到这些库。
WORKDIR /tmp
RUN mkdir -p /mnt/us/python313/lib && \
    # 创建一个临时文件来收集所有依赖库的唯一路径
    touch /tmp/deps.list && \
    # 将 Python 安装的 lib 目录添加到 LD_LIBRARY_PATH，以便 ldd 能够找到内部库
    export LD_LIBRARY_PATH=/mnt/us/python313/lib:$LD_LIBRARY_PATH && \
    \
    # 定义一个函数来查找并收集依赖
    collect_deps() { \
        local target="$1"; \
        # 忽略 ldd 的错误输出，只处理成功找到的依赖
        ldd "$target" 2>/dev/null | grep "=>" | awk '{print $3}' | while read -r lib_path; do \
            # 仅收集不在目标 lib 目录中的库，避免重复和不必要的复制
            if [[ "$lib_path" != "/mnt/us/python313/lib/* ]]; then \
                # 解析符号链接，获取真实路径，并添加到列表中
                readlink -f "$lib_path" >> /tmp/deps.list; \
            fi; \
        done; \
    }; \
    \
    # 收集主 Python 可执行文件的依赖
    collect_deps /mnt/us/python313/bin/python$PYTHON_MAJOR_MINOR && \
    # 收集 Python 共享库的依赖
    collect_deps /mnt/us/python313/lib/libpython$PYTHON_MAJOR_MINOR.so && \
    # 收集动态加载模块的依赖
    find /mnt/us/python313/lib/python$PYTHON_MAJOR_MINOR/lib-dynload -name "*.so" -exec sh -c 'collect_deps "{}"' \; && \
    # 显式添加 musl libc (libc.so) 的真实路径
    readlink -f /lib/libc.so.* >> /tmp/deps.list && \
    \
    # 将收集到的唯一库复制到最终目标目录
    sort -u /tmp/deps.list | while read -r unique_lib_path; do \
        cp -L "$unique_lib_path" /mnt/us/python313/lib/; \
    done && \
    # 清理临时文件
    rm -f /tmp/deps.list; \
    \
    # 5. 调整 Python 可执行文件和共享库的 RPATH
    #    $ORIGIN 表示可执行文件或库本身的目录。
    #    对于 /mnt/us/python313/bin/python3.13，RPATH 设置为 '$ORIGIN/../lib'，即 /mnt/us/python313/lib
    patchelf --set-rpath '$ORIGIN/../lib' /mnt/us/python313/bin/python$PYTHON_MAJOR_MINOR && \
    #    对于 /mnt/us/python313/lib/libpython3.13.so，RPATH 设置为 '$ORIGIN'，即 /mnt/us/python313/lib
    patchelf --set-rpath '$ORIGIN' /mnt/us/python313/lib/libpython$PYTHON_MAJOR_MINOR.so && \
    #    对于动态加载模块（如 _ssl.so），RPATH 设置为 '$ORIGIN/../../..'，即 /mnt/us/python313/lib
    find /mnt/us/python313/lib/python$PYTHON_MAJOR_MINOR/lib-dynload -name "*.so" -exec patchelf --set-rpath '$ORIGIN/../../..' {} \;

# 6. 创建软链接，方便使用 python3 和 pip 命令
RUN ln -s /mnt/us/python313/bin/python$PYTHON_MAJOR_MINOR /mnt/us/python313/bin/python3 && \
    ln -s /mnt/us/python313/bin/pip$PYTHON_MAJOR_MINOR /mnt/us/python313/bin/pip

# 7. 设置 PATH 环境变量，以便可以直接运行 python3 和 pip
ENV PATH="/mnt/us/python313/bin:$PATH"

# 8. 设置默认命令（根据你的实际应用修改）
CMD ["python3"]
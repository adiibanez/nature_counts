CUDA_VER?=
ifeq ($(CUDA_VER),)
$(error "CUDA_VER is not set")
endif

CC:= g++

CFLAGS:= -Wall -std=c++11 -shared -fPIC -Wno-error=deprecated-declarations
CFLAGS+= -I/opt/nvidia/deepstream/deepstream/sources/includes -I/usr/local/cuda-$(CUDA_VER)/include

LIBS+= -lnvinfer_plugin -lnvinfer -L/usr/local/cuda-$(CUDA_VER)/lib64 -lcudart
LFLAGS:= -shared -Wl,--start-group $(LIBS) -Wl,--end-group

TARGET_LIB:= libnvdsinfer_custom_impl_rfdetr.so

SRCFILES:= nvdsparsebbox_rfdetr.cpp
TARGET_OBJS:= $(SRCFILES:.cpp=.o)

all: $(TARGET_LIB)

%.o: %.cpp Makefile
	$(CC) -c -o $@ $(CFLAGS) $<

$(TARGET_LIB): $(TARGET_OBJS)
	$(CC) -o $@ $(TARGET_OBJS) $(LFLAGS)

install: $(TARGET_LIB)
	cp $(TARGET_LIB) ../$(TARGET_LIB)

clean:
	rm -f $(TARGET_LIB) $(TARGET_OBJS)

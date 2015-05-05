CFLAGS=-O3 -g -Wall -m32 -I . -D DEBUG=1
CC=gcc

TARGET=app_h2s
APP_OBJS = app_h2s.o fillbuffer.o

all: $(TARGET) 

$(TARGET): $(APP_OBJS)
	$(CC) $(CFLAGS) $(APP_OBJS) -o $(TARGET) -static -lpthread -lrt -lm

app_h2s.o: ../app_h2s.c
	$(CC) -c $(CFLAGS) -o $@ $<

%.o: %.c
	$(CC) -c $(CFLAGS) -o $@ $<


clean:
	rm -f *.o $(TARGET) 

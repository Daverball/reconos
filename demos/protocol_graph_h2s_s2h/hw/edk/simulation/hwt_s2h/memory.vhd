library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_arith.all;
use ieee.std_logic_unsigned.all;

entity memory is
	port (
		clk  : in  std_logic;
		rst  : in  std_logic;
		addr : in  std_logic_vector(31 downto 0);
		di   : in  std_logic_vector(31 downto 0);
		do   : out std_logic_vector(31 downto 0);
		we   : in std_logic
	);
end memory;

architecture Behavioral of memory is
	constant C_MEM_SIZE : natural := 2048;-- 0x00000000 ... 0x00000800
	constant C_NUM_PACKETS : natural := 16;
	constant C_PACKET_SIZE : natural := 64;
	type MEM_T is array (0 to C_MEM_SIZE-1) of std_logic_vector(31 downto 0);
	signal mem : MEM_T;
begin

	do <= mem(CONV_INTEGER(addr));
	
	process(clk,rst)
	variable mem_index : integer range 0 to C_MEM_SIZE-1;
	begin
		if rising_edge(clk) then
			if rst = '1' then
				for i in 0 to C_MEM_SIZE-1 loop
					mem(i) <= x"DA" & CONV_STD_LOGIC_VECTOR(C_MEM_SIZE-1 - i,24); -- 0x00000FFF ... 0x00000000; sort: 0x00000FFF ... 0x00000800
				end loop;
				mem(0) <= conv_std_logic_vector(C_NUM_PACKETS,32);
				mem_index := 1;
				for i in 1 to C_NUM_PACKETS loop -- fill memory with some packets
					mem(mem_index) <= x"0000" & conv_std_logic_vector(C_PACKET_SIZE-12 + (i mod 4), 16); --noc header
					mem(mem_index+1) <= x"00000000"; -- src idp
					mem(mem_index+2) <= x"00000000"; -- dst idp
					mem_index := mem_index + 3;
					for j in 1 to (C_PACKET_SIZE-12)/4 loop
						mem(mem_index) <= x"A1A2A3" & conv_std_logic_vector(j,8);
						mem_index := mem_index + 1;
					end loop;
					case (i mod 4) is
						when 0 =>
							mem_index := mem_index -1; --step back to previous word
							mem(mem_index) <= x"F1F2F3F4"; --final word
						when 1 =>
							mem(mem_index) <= x"F1000000"; --final word
						when 2 =>
							mem(mem_index) <= x"F1F20000"; --final word
						when 3 =>
							mem(mem_index) <= x"F1F2F300"; --final word
					end case;
					mem_index := mem_index + 1;
				end loop;
			elsif we = '1' then
				mem(CONV_INTEGER(addr)) <= di;
			end if;
		end if;
	end process;

end Behavioral;


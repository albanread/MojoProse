#include <OS.h>

#include <atomic>
#include <iostream>
#include <string>
#include <thread>
#include <vector>

int
main()
{
	std::atomic<int> count{0};
	std::vector<std::thread> threads;
	for (int i = 0; i < 4; i++)
		threads.emplace_back([&count] { count += 1; });
	for (std::thread& thread : threads)
		thread.join();

	system_info info;
	get_system_info(&info);
	std::string what = "clang " + std::to_string(__clang_major__) + " for Haiku";
	std::cout << "hello from " << what << ": " << count.load() << " threads joined, "
		<< info.cpu_count << " CPUs" << std::endl;
	return 0;
}

#include <iostream>
#include <vector>
#include <fstream>
#include <random>
#include <stdint.h>
#include <algorithm>

using namespace std;

typedef uint64_t EdgeT;

void print_workload(uint64_t nodes, uint64_t edges) {
    uint64_t col_bytes =
        8 +                      // vertex_header
        8 +                      // dummy_type
        (nodes + 1) * sizeof(uint64_t);

    uint64_t dst_bytes =
        8 +                      // edge_count
        8 +                      // dummy_type
        edges * sizeof(uint64_t);

    uint64_t total_bytes = col_bytes + dst_bytes;

    double avg_degree = (double)edges / (double)nodes;

    cout << "\n===== Graph Workload Summary =====\n";
    cout << "Nodes           : " << nodes << endl;
    cout << "Edges           : " << edges << endl;
    cout << "Average Degree  : " << avg_degree << endl;

    cout << "\nFile Sizes\n";
    cout << ".col size       : " << col_bytes / (1024.0 * 1024.0) << " MB\n";
    cout << ".dst size       : " << dst_bytes / (1024.0 * 1024.0) << " MB\n";

    cout << "\nTotal Data Written : "
         << total_bytes / (1024.0 * 1024.0) << " MB\n";

    cout << "==================================\n\n";
}

void generate_random_graph(string output_prefix, uint64_t node_count, uint64_t edge_count) {

    vector<uint64_t> offsets(node_count + 1, 0);
    
    mt19937_64 rng(42); 
    uniform_int_distribution<uint64_t> dist(0, node_count - 1);

    cout << "Step 1: Calculating offsets for " << node_count << " nodes..." << endl;
    
    for (uint64_t i = 0; i < edge_count; ++i) {
        offsets[dist(rng)]++;
    }

    uint64_t current_offset = 0;
    for (uint64_t i = 0; i < node_count; ++i) {
        uint64_t degree = offsets[i];
        offsets[i] = current_offset;
        current_offset += degree;
    }
    offsets[node_count] = current_offset;

    string col_name = output_prefix + ".col";
    ofstream col_file(col_name, ios::out | ios::binary);
    uint64_t vertex_header = node_count + 1;
    uint64_t dummy_type = 1;
    
    col_file.write((char*)&vertex_header, 8);
    col_file.write((char*)&dummy_type, 8);
    col_file.write((char*)offsets.data(), (node_count + 1) * sizeof(uint64_t));
    col_file.close();
    cout << "Finished " << col_name << endl;

    // 3. Write the .dst file (Streaming)
    string dst_name = output_prefix + ".dst";
    ofstream dst_file(dst_name, ios::out | ios::binary);
    
    dst_file.write((char*)&edge_count, 8);
    dst_file.write((char*)&dummy_type, 8);

    cout << "Step 2: Streaming " << edge_count << " random edges..." << endl;
    
    const uint64_t CHUNK_SIZE = 1000000;
    vector<EdgeT> buffer;
    buffer.reserve(CHUNK_SIZE);

    for (uint64_t i = 0; i < edge_count; ++i) {
        buffer.push_back(dist(rng));
        if (buffer.size() >= CHUNK_SIZE) {
            dst_file.write((char*)buffer.data(), buffer.size() * sizeof(EdgeT));
            buffer.clear();
        }
    }
    if (!buffer.empty()) {
        dst_file.write((char*)buffer.data(), buffer.size() * sizeof(EdgeT));
    }
    
    dst_file.close();
    cout << "Finished " << dst_name << endl;
    cout << "Graph Generation Complete!" << endl;
}

int main(int argc, char* argv[]) {
    if (argc < 4) {
        cout << "Usage: ./generator <output_prefix> <num_nodes> <num_edges>" << endl;
        cout << "Example: ./generator big_graph 1000000 10000000" << endl;
        return 1;
    }

    string prefix = argv[1];
    uint64_t n = stoull(argv[2]);
    uint64_t m = stoull(argv[3]);

    print_workload(n, m);

    generate_random_graph(prefix, n, m);
    return 0;
}
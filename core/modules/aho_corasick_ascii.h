#include <cstring>
#include <queue>
#include <vector>
#include <iostream>
#include <stdio.h>
#include <map>

static const int MAXS = 500;
static const int MAXC = 256;

namespace {
    std::map<int, std::vector<int> > out;

    int f[MAXS];

    int g[MAXS][MAXC];
}

int buildMatchingMachine(std::string arr[], int k)
{
    // Initialize all values in output function as 0.
    // memset(out, 0, sizeof out);
 
    // Initialize all values in goto function as -1.
    memset(g, -1, sizeof g);
 
    // Initially, we just have the 0 state
    int states = 1;
 
    // Construct values for goto function, i.e., fill g[][]
    // This is same as building a Trie for arr[]
    for (int i = 0; i < k; ++i)
    {
        const std::string &word = arr[i];
        int currentState = 0;
 
        // Insert all characters of current word in arr[]
        for (size_t j = 0; j < word.size(); ++j)
        {
            int ch = (int) word[j];
 
            // Allocate a new node (create a new state) if a
            // node for ch doesn't exist.
            if (g[currentState][ch] == -1)
                g[currentState][ch] = states++;
 
            currentState = g[currentState][ch];
        }
 
        // Add current word in output function
        std::vector<int> output;
        output.push_back(i);
        out.insert(std::make_pair(currentState, output));
    }
 
    // For all characters which don't have an edge from
    // root (or state 0) in Trie, add a goto edge to state
    // 0 itself
    for (int ch = 0; ch < MAXC; ++ch)
        if (g[0][ch] == -1)
            g[0][ch] = 0;
 
    // Now, let's build the failure function
 
    // Initialize values in fail function
    memset(f, -1, sizeof f);
 
    // Failure function is computed in breadth first order
    // using a std::queue
    std::queue<int> q;
 
     // Iterate over every possible input
    for (int ch = 0; ch < MAXC; ++ch)
    {
        // All nodes of depth 1 have failure function value
        // as 0. For example, in above diagram we move to 0
        // from states 1 and 3.
        if (g[0][ch] != 0)
        {
            f[g[0][ch]] = 0;
            q.push(g[0][ch]);
        }
    }
 
    // Now std::queue has states 1 and 3
    while (q.size())
    {
        // Remove the front state from std::queue
        int state = q.front();
        q.pop();
 
        // For the removed state, find failure function for
        // all those characters for which goto function is
        // not defined.
        for (int ch_idx = 0; ch_idx <  MAXC; ch_idx++)
        {
            if (g[state][ch_idx] != -1)
            {
                // Find failure state of removed state
                int failure = f[state];
 
                // Find the deepest node labeled by proper
                // suffix of std::string from root to current
                // state.
                while (g[failure][ch_idx] == -1)
                      failure = f[failure];
 
                failure = g[failure][ch_idx];
                f[g[state][ch_idx]] = failure;
 
                // Merge output values (add the dictionary links)
                // out[g[state][ch_idx]] |= out[failure];

                auto failure_it = out.find(failure);
               
                if (failure_it != out.end()) {
                    auto dictionary_it = out.find(g[state][ch_idx]);
                    
                    auto output_list = dictionary_it->second;
                    auto failure_list = failure_it->second;

                    output_list.insert(output_list.end(), failure_list.begin(), failure_list.end());
                }
 
                // Insert the next level node (of Trie) in std::queue
                q.push(g[state][ch_idx]);
            }
        }
    }

    return states;
}
 
// Returns the next state the machine will transition to using goto
// and failure functions.
// currentState - The current state of the machine. Must be between
//                0 and the number of states - 1, inclusive.
// nextInput - The next character that enters into the machine.
int findNextState(int currentState, char nextInput)
{
    int answer = currentState;
    int ch = (int) nextInput;
 
    // If goto is not defined, use failure function
    while (g[answer][ch] == -1)
        answer = f[answer];
 
    return g[answer][ch];
}
 
// This function finds all occurrences of all array words
// in text.
std::vector<int> searchKeywords(int k, std::string text)
{
    std::vector<int> results;
 
    // Initialize current state
    int currentState = 0;
 
    // Traverse the text through the nuilt machine to find
    // all occurrences of words in arr[]
    for (size_t i = 0; i < text.size(); ++i)
    {
        currentState = findNextState(currentState, text[i]);
 
        // If match not found, move to next state
        auto it = out.find(currentState);
        if (it == out.end())
             continue;
 
        // Match found, print all matching words of arr[]
        // using output function.

        auto outputs = it->second;
        for (auto outputs_it = outputs.begin() ; outputs_it != outputs.end(); outputs_it++)
        {
            results.insert(results.end(), outputs.begin(), outputs.end());
        }
    }

    return results;
}
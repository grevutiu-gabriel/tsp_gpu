#include <stdio.h>
#include <stdlib.h>
#include <cuda_runtime.h>
#include <cuda.h>
#include <math.h>


#define N 10000 
#define t_num 1024
#define GRID_SIZE 512000
 
 /*
 Some compliation options that can speed things up
 --use_fast_math 
 --optimize=5
 --gpu-architecture=compute_35
 I use something like
  nvcc --optimize=5 --use_fast_math -arch=compute_35 tsp_cuda.cu -o tsp_cuda
 */
 /* BEGIN KERNEL
Input:
- city_one: [unsigned integer(threads)]
    - Vector of cities to swap for the first swap choice
- city_two: [unsinged integer(threads)]
    - Vector of cities to swap for the second swap choice
- dist: [float(N * N)] 
    - Distance matrix of each city
- salesman_route: [unsigned integer(N)]
    - Vector of the route the salesman will travel
- original_loss: [float(1)]
    - The original trips loss function
- new_loss: [float(threads)]
    - Vector of values for the proposed trips loss function
- T: [float(1)]
    - The current temperature
- r: [float(threads)]
    - The random number to compare against for S.A.
*/
 __global__ static void tspLoss(const unsigned int* __restrict__ city_one,
                                const unsigned int* __restrict__ city_two,
                                const float * __restrict__ dist,
                                const unsigned int* __restrict__ salesman_route,
                                const float* __restrict__ original_loss, float *new_loss,
                                const float* __restrict__ T,
                                const float* __restrict__ r,
                                 unsigned int* flag){
    
    const int tid = blockIdx.x * blockDim.x + threadIdx.x;
    float delta, p, b = 1;
    float sum = 0;
    //__shared__ int volatile winner[1];
    //winner[0] = 0;
    // make the proposal route
    unsigned int proposal_route[N];
    for (int i = 0; i < N; i++)
        proposal_route[i] = salesman_route[i];
    
    // Do the switch    
    proposal_route[city_one[tid]] = salesman_route[city_two[tid]];
    proposal_route[city_two[tid]] = salesman_route[city_one[tid]];
    
    // evaluate new route's loss function
    for (int i = 0; i < N - 1; i++)
         sum += dist[proposal_route[i] * N + proposal_route[i + 1]];
    
    /* We're going to start trying the trap here
    */
    // Acceptance / Rejection step
    if (sum < original_loss[0]){
        
        new_loss[tid] = sum;
        flag[tid] = 1;
        //winner[0] = 1;
    } 
    /* 
      We would have a kill switch here. If the shared memory var winner has changed to 1,
        then we know someone has already won and we can kill everything else
    
    if (winner[0]){
      __syncthreads();  
      something something kill
    */  
    if (sum >= original_loss[0]){
        delta = sum - original_loss[0];
        p = exp(-(delta * b / T[0]));
        if (p > r[tid]){
            //winner[0] = 1;
            flag[tid] = 1;
            new_loss[tid] = sum;
        } 
    }
    /*
    if (winner[0]){
      __syncthreads();  
      something something kill
    */  
      
 }
 // END KERNEL
 
 
 /* Function to generate random numbers in interval
 
 input:
- min [unsigned integer(1)]
  - The minimum number to sample
- max [unsigned integer(1)]
  - The maximum number to sample
  
  Output: [unsigned integer(1)]
    - A randomly generated number between the range of min and max
    
  Desc:
  Taken from
  - http://stackoverflow.com/questions/2509679/how-to-generate-a-random-number-from-within-a-range
  
  
 */
 unsigned int rand_interval(unsigned int min, unsigned int max)
{
    int r;
    const unsigned int range = 1 + max - min;
    const unsigned int buckets = RAND_MAX / range;
    const unsigned int limit = buckets * range;

    /* Create equal size buckets all in a row, then fire randomly towards
     * the buckets until you land in one of them. All buckets are equally
     * likely. If you land off the end of the line of buckets, try again. */
    do
    {
        r = rand();
    } while (r >= limit);

    return min + (r / buckets);
}



 int main(){
 
     // start counters for cities
     unsigned int i, j, m;
     
     // city's x y coordinates
     struct coordinates {
         int x;
         int y;
     };
     
     struct coordinates location[N];
     
     unsigned int *salesman_route = (unsigned int *)malloc(N * sizeof(unsigned int));
     
     // just make one inital guess route, a simple linear path
     for (i = 0; i < N; i++)
         salesman_route[i] = i;
         
     // Set the starting and end points to be the same
     salesman_route[N-1] = salesman_route[0];
     
     // initialize the coordinates and sequence
     for(i = 0; i < N; i++){
         location[i].x = rand() % 1000;
         location[i].y = rand() % 1000;
     }
     
     // distance
     //float dist[N * N];
     float *dist = (float *)malloc(N * N * sizeof(float));
     
     printf("Computing Distance matrix of size %d:\n", N);
     for(i = 0; i < N; i++){
         for (j = 0; j < N; j++){
             // Calculate the euclidian distance between each city
             // use pow() here instead?
             dist[i * N + j] = (location[i].x - location[j].x) * (location[i].x - location[j].x) +
                               (location[j].y - location[j].y) * (location[i].y - location[j].y);
         }
     }
     printf("Finished Computing Distance matrix of size %d:\n", N);
     // Calculate the original loss
     float original_loss = 0;
     for (i = 0; i < N - 1; i++){
         original_loss += dist[salesman_route[i] * N + salesman_route[i+1]];
     }
     printf("Original Loss is: %.6f \n", original_loss);
     // Keep the original loss for comparison pre/post algorithm
     float starting_loss = original_loss;
     float *dist_g, T = 999999999, *T_g, *r_g;
     float *r_h = (float *)malloc(GRID_SIZE * sizeof(float));
     /*
     Defining device variables:
     city_swap_one_h/g: [integer(t_num)]
       - Host/Device memory for city one
     city_swap_two_h/g: [integer(t_num)]
       - Host/Device memory for city two
     flag_h/g: [integer(t_num)]
       - Host/Device memory for flag of accepted step
     salesman_route_g: [integer(N)]
       - Device memory for the salesmans route
     r_g:  [float(t_num)]
       - Device memory for the random number when deciding acceptance
     flag_h/g: [integer(t_num)]
       - host/device memory for acceptance vector
     original_loss_g: [integer(1)]
       - The device memory for the current loss function
     new_loss_h/g: [integer(t_num)]
       - The host/device memory for the proposal loss function
     */
     unsigned int *city_swap_one_h = (unsigned int *)malloc(GRID_SIZE * sizeof(unsigned int));
     unsigned int *city_swap_two_h = (unsigned int *)malloc(GRID_SIZE * sizeof(unsigned int));
     unsigned int *flag_h = (unsigned int *)malloc(GRID_SIZE * sizeof(unsigned int));
     unsigned int *city_swap_one_g, *city_swap_two_g, *salesman_route_g, *flag_g;

     float *original_loss_g, *new_loss_g;
     float *new_loss_h = (float *)malloc(GRID_SIZE * sizeof(float)); 
     
     cudaError_t err = cudaMalloc((void**)&city_swap_one_g, GRID_SIZE * sizeof(unsigned int));
     //printf("\n Cuda malloc city swap one: %s \n", cudaGetErrorString(err));
     cudaMalloc((void**)&city_swap_two_g, GRID_SIZE * sizeof(unsigned int));
     cudaMalloc((void**)&dist_g, N * N * sizeof(float));
     cudaMalloc((void**)&salesman_route_g, N * sizeof(unsigned int));
     cudaMalloc((void**)&original_loss_g, sizeof(float));
     cudaMalloc((void**)&new_loss_g, GRID_SIZE * sizeof(float));
     cudaMalloc((void**)&T_g, sizeof(float));
     cudaMalloc((void**)&r_g, GRID_SIZE * sizeof(float));
     cudaMalloc((void**)&flag_g, GRID_SIZE * sizeof(unsigned int));
     
     
     cudaMemcpy(dist_g, dist, (N*N) * sizeof(float), cudaMemcpyHostToDevice);
     // Beta is the decay rate
     float beta = 0.01;
     float a = T; 
     float f;
     
     while (T > 1){
         // Init parameters
         //printf("Current Temperature is: %.6f:", T);
         for(m = 0; m < GRID_SIZE; m++){
             // pick first city to swap
             city_swap_one_h[m] = rand_interval(1, N-2);
             // f defines how far the second city can be from the first
             f = exp(-a / T);
             j = (unsigned int)floor(1 + city_swap_one_h[m] * f); 
             // pick second city to swap
             city_swap_two_h[m] = (city_swap_one_h[m] + j) % N;
             if (city_swap_two_h[m] == 0)
               city_swap_two_h[m] += 1;
             if (city_swap_two_h[m] == N - 1)
               city_swap_two_h[m] -= 1;
             //printf("\n City one is %d and city two is %d \n", city_swap_one_h[m], city_swap_two_h[m]);
             r_h[m] = (float)rand() / (float)RAND_MAX ;
             
             //set our flags and new loss to 0
             flag_h[m] = 0;
             new_loss_h[m] = 0;
          }
          err = cudaMemcpy(city_swap_one_g, city_swap_one_h, GRID_SIZE * sizeof(unsigned int), cudaMemcpyHostToDevice);
          //printf("\n Cuda mem copy city swap one: %s \n", cudaGetErrorString(err));
          cudaMemcpy(city_swap_two_g, city_swap_two_h, GRID_SIZE * sizeof(unsigned int), cudaMemcpyHostToDevice);
          cudaMemcpy(salesman_route_g, salesman_route, N * sizeof(unsigned int), cudaMemcpyHostToDevice);
          cudaMemcpy(T_g, &T, sizeof(float), cudaMemcpyHostToDevice);
          cudaMemcpy(r_g, r_h, GRID_SIZE * sizeof(float), cudaMemcpyHostToDevice);
          cudaMemcpy(flag_g, flag_h, GRID_SIZE* sizeof(unsigned int), cudaMemcpyHostToDevice);
          cudaMemcpy(original_loss_g, &original_loss, sizeof(float), cudaMemcpyHostToDevice);
          cudaMemcpy(new_loss_g, new_loss_h, GRID_SIZE * sizeof(float), cudaMemcpyHostToDevice);
 
          // Number of thread blocks in grid
          dim3 blocksPerGrid(1,GRID_SIZE/t_num,1);
          dim3 threadsPerBlock(1,t_num,1);
    
          tspLoss<<<blocksPerGrid, threadsPerBlock, 0>>>(city_swap_one_g, city_swap_two_g,
                                                         dist_g, salesman_route_g,
                                                         original_loss_g, new_loss_g,
                                                         T_g, r_g, flag_g);
          cudaThreadSynchronize();          
          cudaMemcpy(flag_h, flag_g, GRID_SIZE * sizeof(unsigned int), cudaMemcpyDeviceToHost);
          cudaMemcpy(new_loss_h, new_loss_g, GRID_SIZE * sizeof(float), cudaMemcpyDeviceToHost);
          /* 
          Here we check for a success
            The first proposal trip accepted becomes the new starting trip 
          */
          for (i = 0; i < GRID_SIZE; i++){
              if (flag_h[i] == 0){
              //printf("Original Loss: %.6f \n", original_loss);
              //printf("Proposed Loss: %.6f \n", new_loss_h[i]);
                  continue;
              } else {
                  // switch the two cities that led to an accepted proposal
                  unsigned int tmp = salesman_route[city_swap_one_h[i]];
                  salesman_route[city_swap_one_h[i]] = salesman_route[city_swap_two_h[i]];
                  salesman_route[city_swap_two_h[i]] = tmp;
                  
                  // set old loss function to new
                  original_loss = new_loss_h[i];
                  //decrease temp
                  T -= T*beta;
                  //if (T < 300){
                    printf(" Current Temperature is %.6f \n", T);
                    printf("\n Current Loss is: %.6f \n", original_loss);
                  //}
                  /*
                  printf("Best found trip so far\n");
                  for (j = 0; j < N; j++){
                     printf("%d ", salesman_route[j]);
                  }
                  */
                  //T -= T*beta;
                  break;
              }
           // We are just going to decrease temp anyway for now
          }   
     }
     printf("The starting loss was %.6f and the final loss was %.6f \n", starting_loss, original_loss);
     /*
     printf("\n Final Route:\n");
     for (i = 0; i < N; i++)
       printf("%d ",salesman_route[i]);
     */    
     cudaFree(city_swap_one_g);
     cudaFree(city_swap_two_g);
     cudaFree(dist_g);
     cudaFree(salesman_route_g);
     cudaFree(T_g);
     cudaFree(r_g);
     cudaFree(flag_g);
     cudaFree(new_loss_g);
     cudaFree(original_loss_g);
     free(dist);
     free(salesman_route);
     free(city_swap_one_h);
     free(city_swap_two_h);
     free(flag_h);
     free(new_loss_h);
     return 0;
}
             
         
         
         
         
